#!/bin/bash

exec > >(tee /var/log/userdata-backend.log | logger -t userdata -s 2>/dev/console) 2>&1

echo "===== [nt-backend] Initialization Start ====="


echo "[Network] Waiting for connectivity to package repositories..."
for i in {1..40}; do
  if apt-get update -qq > /dev/null 2>&1; then
    echo "[Network] Connection established."
    break
  fi
  echo "[Network] Not ready yet... waiting 10s (Attempt $i/20)"
  sleep 10
done

# ── System packages ───────────────────────────────────────────
apt-get update -y
apt-get install -y git curl build-essential mysql-client

# ── Node.js 18 via NVM ────────────────────────────────────────
mkdir -p /root/.nvm
export NVM_DIR="/root/.nvm"
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash

if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "ERROR: NVM installation failed. Script exiting."
  exit 1
fi
echo "[Step 2/5] Loading NVM..."
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
# [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
# source ~/.bashrc

# ── CRITICAL FIX: Export PATH for PM2 and NPM ─────────────────

nvm install 18 && nvm use 18 && nvm alias default 18
export PATH=$NVM_DIR/versions/node/$(nvm current)/bin:$PATH

# ── PM2 process manager ───────────────────────────────────────
npm install -g pm2
npm install dotenv
# npm install prom-client

# ── App directories ───────────────────────────────────────────
mkdir -p /var/app/backend
mkdir -p /var/log/app
chown -R root:root /var/app/backend /var/log/app

# ── Write package.json (Includes dotenv) ──────────────────────
cat > /var/app/backend/package.json << 'PKGJSON'
{
  "name": "nt-backend",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { 
    "mysql2": "^3.9.7",
    "dotenv": "^16.4.5",
    "prom-client": "^15.1.0" 
  }
}
PKGJSON

# ── Write .env ────────────────────────────────────────────────
cat > /var/app/backend/.env << ENVFILE
NODE_ENV=production
PORT=8080
DB_HOST=${db_endpoint}
DB_PORT=${db_port}
DB_NAME=${db_name}
DB_USER=${db_username}
DB_PASSWORD=${db_password}
ENVFILE
chmod 600 /var/app/backend/.env

# ── Write server.js (Includes dotenv config) ───────────────────
cat > /var/app/backend/server.js << 'SERVERJS'
require('dotenv').config();
'use strict';

const http     = require('http');
const mysql    = require('mysql2/promise');
const client = require('prom-client');

// ── Config from environment (injected by userdata) ────────────
const PORT    = process.env.PORT     || 8080;
const DB_HOST = process.env.DB_HOST;
const DB_PORT = parseInt(process.env.DB_PORT || '3306', 10);
const DB_NAME = process.env.DB_NAME;
const DB_USER = process.env.DB_USER;
const DB_PASS = process.env.DB_PASSWORD;

// ── MySQL connection pool ─────────────────────────────────────
let pool;

async function getPool() {
  if (!pool) {
    pool = mysql.createPool({
      host            : DB_HOST,
      port            : DB_PORT,
      database        : DB_NAME,
      user            : DB_USER,
      password        : DB_PASS,
      waitForConnections: true,
      connectionLimit : 10,
      queueLimit      : 0,
      connectTimeout  : 10000,
    });
    // Seed on first connection if table is empty
    await seedIfEmpty(pool);
  }
  return pool;
}

// ── Seed initial data ─────────────────────────────────────────
async function seedIfEmpty(pool) {
  await pool.execute(`
    CREATE TABLE IF NOT EXISTS members (
      id         INT AUTO_INCREMENT PRIMARY KEY,
      name       VARCHAR(100) NOT NULL,
      role       VARCHAR(100) NOT NULL,
      department VARCHAR(100) NOT NULL,
      location   VARCHAR(100) NOT NULL,
      joined_at  DATE NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  `);

  const [rows] = await pool.execute('SELECT COUNT(*) AS cnt FROM members');
  if (rows[0].cnt > 0) return;

  const seed = [
    ['Alice Nguyen',   'Lead Engineer',      'Engineering', 'Singapore',   '2021-03-15'],
    ['Bob Rahman',     'Product Manager',    'Product',     'Kuala Lumpur','2020-07-01'],
    ['Clara Osei',     'UX Designer',        'Design',      'Accra',       '2022-01-10'],
    ['David Kim',      'Backend Developer',  'Engineering', 'Seoul',       '2021-11-22'],
    ['Eva Santos',     'Data Analyst',       'Analytics',   'Sao Paulo',   '2023-02-28'],
    ['Frank Müller',   'DevOps Engineer',    'Platform',    'Berlin',      '2020-09-05'],
    ['Grace Okonkwo',  'Frontend Developer', 'Engineering', 'Lagos',       '2022-06-17'],
    ['Hassan Ali',     'QA Engineer',        'Quality',     'Cairo',       '2021-08-30'],
  ];

  for (const [name, role, department, location, joined_at] of seed) {
    await pool.execute(
      'INSERT INTO members (name, role, department, location, joined_at) VALUES (?, ?, ?, ?, ?)',
      [name, role, department, location, joined_at]
    );
  }
  console.log('[seed] Inserted 8 seed members');
}

// ── NEW: Helper to parse POST body from stream ───────────────
async function getBody(req) {
  return new Promise((resolve, reject) => {
    try {
      let body = '';
      req.on('data', chunk => { body += chunk.toString(); });
      req.on('end', () => { resolve(JSON.parse(body)); });
    } catch (err) { reject(err); }
  });
}
// 1. Collect default CPU/Memory metrics
const collectDefaultMetrics = client.collectDefaultMetrics;
collectDefaultMetrics({ register: client.register });

// 2. Create a Histogram for Request Duration
const httpRequestDurationMicroseconds = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'code'],
  // Buckets: 1s, 2s, 5s
  buckets: [1, 2, 5, 10, 30, 60]
});

// ── Request router ────────────────────────────────────────────
async function handler(req, res) {
  // CORS headers (allowing POST and OPTIONS)
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Content-Type', 'application/json');

  const url = req.url.split('?')[0];

  // Handle Preflight (OPTIONS)
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    return res.end();
  }

  // ── GET /api/health ──────────────────────────────────────
  if (url === '/api/health' && req.method === 'GET') {
    res.writeHead(200);
    return res.end(JSON.stringify({ status: 'ok', timestamp: new Date().toISOString() }));
  }

  // ── GET /api/members ─────────────────────────────────────
  if (url === '/api/members' && req.method === 'GET') {
    try {
      const p     = await getPool();
      const t0    = Date.now();
      const [rows] = await p.execute('SELECT * FROM members ORDER BY joined_at DESC');
      const ms    = Date.now() - t0;

      res.writeHead(200);
      return res.end(JSON.stringify({
        source   : `mysql://$${DB_HOST}/$${DB_NAME}`,
        query_ms : ms,
        members  : rows,
      }));
    } catch (err) {
      console.error('[/api/members] DB error:', err.message);
      res.writeHead(500);
      return res.end(JSON.stringify({ error: 'Database error', detail: err.message }));
    }
  }

  // ── NEW: POST /api/members (Add Member) ───────────────────
  if (url === '/api/members' && req.method === 'POST') {
    try {
      const body = await getBody(req);

      // Basic validation
      if (!body.name || !body.role || !body.department || !body.location || !body.joined_at) {
        res.writeHead(400);
        return res.end(JSON.stringify({ error: 'Missing required fields' }));
      }

      const p = await getPool();
      await p.execute(
        'INSERT INTO members (name, role, department, location, joined_at) VALUES (?, ?, ?, ?, ?)',
        [body.name, body.role, body.department, body.location, body.joined_at]
      );

      res.writeHead(201); // 201 Created
      return res.end(JSON.stringify({ message: 'Member added successfully', member: body }));

    } catch (err) {
      console.error('[POST /api/members] Error:', err.message);
      res.writeHead(500);
      return res.end(JSON.stringify({ error: 'Server error', detail: err.message }));
    }
  }

  // ── 404 ──────────────────────────────────────────────────
  res.writeHead(404);
  res.end(JSON.stringify({ error: 'Not found' }));
}

// ── Start server ──────────────────────────────────────────────
const server = http.createServer(handler);
server.on('request', (req, res) => {
  const start = Date.now();

  res.on('finish', () => {
    const duration = Date.now - start;
    httpRequestDurationMicroseconds.observe({ 
      method: req.method, 
      route: req.url.split('?')[0], 
      code: res.statusCode 
    }, duration / 1000);
  });
});

// 4. Start the Metrics Server (Different Port)
const server_metrics = http.createServer(async (req, res) => {
  res.setHeader('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});

server_metrics.listen(9453, '0.0.0.0', () => {
  console.log('[Metrics] Listening on port 9453');
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[server] Listening on port $${PORT}`);
  console.log(`[server] DB => $${DB_HOST}:$${DB_PORT}/$${DB_NAME}`);
  // Eagerly connect and seed
  getPool().catch(err => console.error('[server] Pool init error:', err.message));
});

// Graceful shutdown
process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
});
SERVERJS

# ── Install dependencies & start ─────────────────────────────
useradd --no-create-home --shell /bin/false node_exporter
cd /tmp
wget https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
tar -xf node_exporter-1.7.0.linux-amd64.tar.gz
cp -f node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/
chown node_exporter:node_exporter /usr/local/bin/node_exporter
rm -rf node_exporter-1.7.0.linux-amd64*
sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<'EOFCF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOFCF

systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

cd /var/app/backend
rm -rf node_modules package-lock.json
npm cache clean --force

echo "[Final] Installing NPM dependencies..."
npm install --legacy-peer-deps --no-audit --no-fund || true


pm2 start server.js --name nt-api
pm2 save

# ── PM2 auto-start on reboot ──────────────────────────────────
# env PATH=$PATH:/root/.nvm/versions/node/$(nvm current)/bin
pm2 startup systemd -u root --hp /root

hostnamectl set-hostname ${project_name}-backend
echo "===== [nt-backend] Init Complete ====="