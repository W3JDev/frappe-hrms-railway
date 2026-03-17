#!/bin/bash
set -e
echo "====================================="
echo " Frappe HRMS - Railway Entrypoint"
echo "====================================="

# --- 1. Start Redis in background (required by Frappe) ---
echo "-> Starting Redis..."
redis-server --daemonize yes --port 11000 --loglevel warning
redis-server --daemonize yes --port 12000 --loglevel warning
redis-server --daemonize yes --port 13000 --loglevel warning
sleep 2
echo "-> Redis started on ports 11000 12000 13000"

# --- 2. Patch common_site_config.json to use local Redis ---
echo "-> Patching common_site_config.json for local Redis..."
python3 -c "
import json, os
path = '/home/frappe/bench/sites/common_site_config.json'
try:
  with open(path, 'r') as f:
    cfg = json.load(f)
except:
  cfg = {}
cfg['redis_cache'] = 'redis://127.0.0.1:13000'
cfg['redis_queue'] = 'redis://127.0.0.1:11000'
cfg['redis_socketio'] = 'redis://127.0.0.1:12000'
with open(path, 'w') as f:
  json.dump(cfg, f, indent=2)
print('Patched common_site_config.json with local Redis')
"

# --- 3. Wait for MariaDB ---
echo "-> Waiting for MariaDB at ${DB_HOST}:${DB_PORT}..."
until mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; do
  echo "   Not ready, retrying in 3s..."
  sleep 3
done
echo "-> MariaDB is ready!"

# --- 4. Always ensure HRMS app code is present (container is ephemeral!) ---
if [ ! -d "/home/frappe/bench/apps/hrms" ]; then
  echo "-> HRMS app code missing. Fetching..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench get-app https://github.com/frappe/hrms --branch version-15"
else
  echo "-> HRMS app code already present."
fi

# --- 5. Check if site DB is fully initialized ---
DB_READY=$(mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  -e "SELECT IF(COUNT(*)>0,'1','0') FROM information_schema.tables WHERE table_schema='frappe_hrms' AND table_name='tabSingles';" \
  -sN 2>/dev/null || echo "0")
SITE_FOLDER_EXISTS=0
[ -d "/home/frappe/bench/sites/site1.local" ] && SITE_FOLDER_EXISTS=1
echo "-> DB_READY=$DB_READY SITE_FOLDER_EXISTS=$SITE_FOLDER_EXISTS"

if [ "$DB_READY" = "1" ] && [ "$SITE_FOLDER_EXISTS" = "1" ]; then
  echo "-> Site and DB both ready. Skipping full setup."
else
  echo "-> Setup needed. Running full setup..."

  # Start HTTP placeholder so Railway health check passes during setup
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
print('HTTP placeholder started on port 8000')
time.sleep(99999)
" &
  PLACEHOLDER_PID=$!
  sleep 2

  rm -rf /home/frappe/bench/sites/site1.local

  echo "-> Dropping stale DB and users..."
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "DROP DATABASE IF EXISTS frappe_hrms;" 2>/dev/null || true
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "SELECT CONCAT('DROP USER IF EXISTS \`',user,'\`@\`%\`;') FROM mysql.user WHERE user LIKE '\_%';" \
    -sN 2>/dev/null | mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" 2>/dev/null || true
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "FLUSH PRIVILEGES;" 2>/dev/null || true

  echo "-> Running bench new-site..."
  su -s /bin/bash frappe -c "
    cd /home/frappe/bench && \\
    bench new-site site1.local \\
      --mariadb-root-username root \\
      --mariadb-root-password '${MYSQL_ROOT_PASSWORD}' \\
      --db-host '${DB_HOST}' \\
      --db-port '${DB_PORT}' \\
      --db-name frappe_hrms \\
      --db-password '${RFP_SITE_ADMIN_PASSWORD}' \\
      --admin-password '${RFP_SITE_ADMIN_PASSWORD:-admin}' \\
      --no-mariadb-socket \\
      --install-app erpnext
  "

  echo "-> Installing HRMS..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local install-app hrms"

  echo "-> Running migrate..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local migrate --skip-failing"

  kill $PLACEHOLDER_PID 2>/dev/null || true
  sleep 2
fi

# --- 6. Always patch site_config.json db_host ---
echo "-> Patching site_config.json db_host..."
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

# --- 7. Recreate DB user with correct password ---
echo "-> Recreating DB user with correct password..."
python3 -c "
import json, subprocess, os
path = '/home/frappe/bench/sites/site1.local/site_config.json'
with open(path, 'r') as f:
  cfg = json.load(f)
db_name = cfg.get('db_name', 'frappe_hrms')
db_password = cfg.get('db_password', '')
if not db_password:
  print('No db_password in site_config, skipping')
else:
  host = os.environ['DB_HOST']
  port = os.environ.get('DB_PORT', '3306')
  root_pass = os.environ['MYSQL_ROOT_PASSWORD']
  sql = \"DROP USER IF EXISTS '{u}'@'%'; CREATE USER '{u}'@'%' IDENTIFIED BY '{p}'; GRANT ALL PRIVILEGES ON \`{db}\`.* TO '{u}'@'%'; FLUSH PRIVILEGES;\".format(u=db_name, p=db_password, db=db_name)
  result = subprocess.run(
    ['mysql', '-h', host, '-P', port, '-uroot', '-p'+root_pass, '-e', sql],
    capture_output=True, text=True
  )
  if result.returncode == 0:
    print('DB user recreated OK: ' + db_name)
  else:
    print('ERROR: ' + result.stderr)
    exit(1)
"

# --- 8. Reset admin password to RFP_SITE_ADMIN_PASSWORD ---
echo "-> Resetting admin password..."
su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local set-admin-password '${RFP_SITE_ADMIN_PASSWORD:-admin}'" || true

# --- 9. Set default site ---
echo "-> Setting default site..."
su -s /bin/bash frappe -c "cd /home/frappe/bench && bench use site1.local" || true

# --- 10. Start bench serve ---
echo "-> Starting Frappe HRMS..."
exec su -s /bin/bash frappe -c "cd /home/frappe/bench && bench serve --port 8000"
