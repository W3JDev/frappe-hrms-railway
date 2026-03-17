#!/bin/bash
echo "====================================="
echo " Frappe HRMS - Railway Entrypoint"
echo "====================================="

# --- 0. Patch db_host IMMEDIATELY for existing sites ---
echo "-> Patching db_host in site_config if site exists..."
SITE_CONFIG="/home/frappe/bench/sites/site1.local/site_config.json"
if [ -f "$SITE_CONFIG" ]; then
  python3 -c "
import json, os
with open('$SITE_CONFIG', 'r') as f:
    cfg = json.load(f)
cfg['db_host'] = os.environ['DB_HOST']
cfg['db_port'] = int(os.environ.get('DB_PORT', 3306))
with open('$SITE_CONFIG', 'w') as f:
    json.dump(cfg, f, indent=2)
print('site_config.json patched with db_host=' + os.environ['DB_HOST'])
"
fi
echo '{"db_host": "'"${DB_HOST}"'", "db_port": '"${DB_PORT:-3306}"'}' > /home/frappe/bench/sites/common_site_config.json

# --- 1. Wait for MariaDB ---
echo "-> Waiting for MariaDB at ${DB_HOST}:${DB_PORT}..."
until mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; do
  echo "  Not ready, retrying in 3s..."
  sleep 3
done
echo "-> MariaDB is ready!"

# --- 2. Check if DB tables exist ---
DB_READY=$(mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='frappe_hrms' AND table_name='tabSingles';" \
  -sN 2>/dev/null || echo "0")

if [ "$DB_READY" != "1" ]; then
  echo "-> DB not initialized. Running full setup..."

  # Start Python HTTP placeholder on port 8000 to pass Railway health check
  echo "-> Starting HTTP placeholder on port 8000..."
  python3 -c "
import http.server, threading, time
class H(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
    self.send_response(200)
    self.end_headers()
    self.wfile.write(b'Setting up...')
  def log_message(self, *a): pass
s = http.server.HTTPServer(('0.0.0.0', 8000), H)
t = threading.Thread(target=s.serve_forever)
t.daemon = True
t.start()
print('Placeholder ready')
time.sleep(99999)
" &
  PLACEHOLDER_PID=$!
  echo "-> Placeholder PID: $PLACEHOLDER_PID"
  sleep 2

  # --- 3. Drop old stale site if exists ---
  if [ -d "/home/frappe/bench/sites/site1.local" ]; then
    echo "-> Removing stale site1.local directory..."
    rm -rf /home/frappe/bench/sites/site1.local
  fi

  # --- 4. Drop existing DB so bench can create it fresh ---
  echo "-> Dropping existing frappe_hrms DB if present..."
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "DROP DATABASE IF EXISTS frappe_hrms; DROP USER IF EXISTS 'frappe_hrms'@'%'; FLUSH PRIVILEGES;" 2>/dev/null || true
  echo "-> Old DB/user cleared."

  # --- 5. Get HRMS app if not present ---
  if [ ! -d "/home/frappe/bench/apps/hrms" ]; then
    echo "-> Downloading HRMS app..."
    su -s /bin/bash frappe -c "cd /home/frappe/bench && bench get-app https://github.com/frappe/hrms --branch version-15"
  else
    echo "-> HRMS already present."
  fi

  # --- 6. bench new-site: let bench create the DB itself ---
  echo "-> Running bench new-site (takes 15-20 min, placeholder keeps port alive)..."
  su -s /bin/bash frappe -c "
    cd /home/frappe/bench && \
    bench new-site site1.local \
      --mariadb-root-username root \
      --mariadb-root-password '${MYSQL_ROOT_PASSWORD}' \
      --db-host '${DB_HOST}' \
      --db-port '${DB_PORT}' \
      --db-name frappe_hrms \
      --db-password '${RFP_SITE_ADMIN_PASSWORD}' \
      --admin-password '${RFP_SITE_ADMIN_PASSWORD:-admin}' \
      --no-mariadb-socket \
      --install-app erpnext
    "

  # --- 6.5. Patch site_config.json after new-site ---
  echo "-> Patching site_config.json with correct db_host after bench new-site..."
  python3 -c "
import json, os
path = '/home/frappe/bench/sites/site1.local/site_config.json'
with open(path, 'r') as f:
    cfg = json.load(f)
cfg['db_host'] = os.environ['DB_HOST']
cfg['db_port'] = int(os.environ.get('DB_PORT', 3306))
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
print('Patched site_config.json db_host=' + os.environ['DB_HOST'])
"

  # --- 7. Install HRMS ---
  echo "-> Installing HRMS..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local install-app hrms"

  # --- 8. Migrate ---
  echo "-> Running migrations..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local migrate --skip-failing"

  echo "-> Setup complete! Killing placeholder..."
  kill $PLACEHOLDER_PID 2>/dev/null || true
  sleep 2
else
  echo "-> tabSingles exists — DB already set up. Skipping new-site."
fi

# --- 9. Start bench ---
echo "-> Starting Frappe HRMS..."
exec su -s /bin/bash frappe -c "cd /home/frappe/bench && bench start"
