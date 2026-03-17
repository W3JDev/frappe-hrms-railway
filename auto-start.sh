#!/bin/bash
echo "====================================="
echo " Frappe HRMS - Railway Entrypoint"
echo "====================================="

# --- 1. Wait for MariaDB ---
echo "-> Waiting for MariaDB at ${DB_HOST}:${DB_PORT}..."
until mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; do
  echo "  Not ready, retrying in 3s..."
  sleep 3
done
echo "-> MariaDB is ready!"

# --- 2. Check ALL three conditions: tabSingles in DB + site folder + correct db_name ---
DB_READY=$(mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='frappe_hrms' AND table_name='tabSingles';" \
  -sN 2>/dev/null || echo "0")

SITE_FOLDER_EXISTS=0
[ -d "/home/frappe/bench/sites/site1.local" ] && SITE_FOLDER_EXISTS=1

SITE_DB_NAME=""
if [ -f "/home/frappe/bench/sites/site1.local/site_config.json" ]; then
  SITE_DB_NAME=$(python3 -c "import json; print(json.load(open('/home/frappe/bench/sites/site1.local/site_config.json')).get('db_name',''))" 2>/dev/null || echo "")
fi

echo "-> DB_READY=$DB_READY  SITE_FOLDER=$SITE_FOLDER_EXISTS  SITE_DB_NAME=$SITE_DB_NAME"

if [ "$DB_READY" = "1" ] && [ "$SITE_FOLDER_EXISTS" = "1" ] && [ "$SITE_DB_NAME" = "frappe_hrms" ]; then
  echo "-> All checks passed. Patching db_host and starting bench..."
  python3 -c "
import json, os
path = '/home/frappe/bench/sites/site1.local/site_config.json'
with open(path, 'r') as f:
    cfg = json.load(f)
cfg['db_host'] = os.environ['DB_HOST']
cfg['db_port'] = int(os.environ.get('DB_PORT', 3306))
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
print('Patched db_host=' + os.environ['DB_HOST'])
"
else
  echo "-> Setup needed (DB=$DB_READY, FOLDER=$SITE_FOLDER_EXISTS, DB_NAME=$SITE_DB_NAME). Starting full setup..."

  # HTTP placeholder on port 8000 so Railway health check passes during long setup
  python3 -c "
import http.server, threading, time
class H(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
    self.send_response(200)
    self.end_headers()
    self.wfile.write(b'Setting up Frappe HRMS...')
  def log_message(self, *a): pass
s = http.server.HTTPServer(('0.0.0.0', 8000), H)
t = threading.Thread(target=s.serve_forever)
t.daemon = True
t.start()
print('HTTP placeholder on port 8000 ready')
time.sleep(99999)
" &
  PLACEHOLDER_PID=$!
  sleep 2

  # Wipe stale site folder
  rm -rf /home/frappe/bench/sites/site1.local

  # Drop stale DB and ALL underscore users left from old bench runs
  echo "-> Clearing stale DB and users..."
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "DROP DATABASE IF EXISTS frappe_hrms;" 2>/dev/null || true
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "SELECT CONCAT('DROP USER IF EXISTS \`',user,'\`@\`%\`;') FROM mysql.user WHERE user LIKE '\_%';" \
    -sN 2>/dev/null | mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" 2>/dev/null || true
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "FLUSH PRIVILEGES;" 2>/dev/null || true
  echo "-> Cleared."

  # Get HRMS app if missing
  if [ ! -d "/home/frappe/bench/apps/hrms" ]; then
    echo "-> Fetching HRMS app..."
    su -s /bin/bash frappe -c "cd /home/frappe/bench && bench get-app https://github.com/frappe/hrms --branch version-15"
  fi

  # bench new-site with frappe_hrms as db_name
  echo "-> Running bench new-site..."
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

  # Immediately patch db_host after new-site (bench may write 127.0.0.1)
  echo "-> Patching site_config.json db_host after new-site..."
  python3 -c "
import json, os
path = '/home/frappe/bench/sites/site1.local/site_config.json'
with open(path, 'r') as f:
    cfg = json.load(f)
cfg['db_host'] = os.environ['DB_HOST']
cfg['db_port'] = int(os.environ.get('DB_PORT', 3306))
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
print('Patched db_host=' + os.environ['DB_HOST'])
"

  # Install HRMS
  echo "-> Installing HRMS..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local install-app hrms"

  # Migrate
  echo "-> Migrating..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local migrate --skip-failing"

  echo "-> Full setup complete. Killing placeholder..."
  kill $PLACEHOLDER_PID 2>/dev/null || true
  sleep 2
fi

# --- Start bench ---
echo "-> Starting Frappe HRMS..."
exec su -s /bin/bash frappe -c "cd /home/frappe/bench && bench start"
