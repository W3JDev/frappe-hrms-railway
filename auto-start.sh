#!/bin/bash
set -e
echo "====================================="
echo " Frappe HRMS - Railway Entrypoint"
echo "====================================="

# --- 1. Wait for MariaDB ---
echo "-> Waiting for MariaDB at ${DB_HOST}:${DB_PORT}..."
until mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; do
  echo "   Not ready, retrying in 3s..."
  sleep 3
done
echo "-> MariaDB is ready!"

# --- 2. Check if site DB has tabSingles (fully initialized) ---
DB_READY=$(mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  -e "SELECT IF(COUNT(*)>0,'1','0') FROM information_schema.tables WHERE table_schema='frappe_hrms' AND table_name='tabSingles';" \
  -sN 2>/dev/null || echo "0")
SITE_FOLDER_EXISTS=0
[ -d "/home/frappe/bench/sites/site1.local" ] && SITE_FOLDER_EXISTS=1
echo "-> DB_READY=$DB_READY SITE_FOLDER_EXISTS=$SITE_FOLDER_EXISTS"

if [ "$DB_READY" = "1" ] && [ "$SITE_FOLDER_EXISTS" = "1" ]; then
  echo "-> Site and DB both ready. Skipping setup."
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

  # Wipe stale site folder
  rm -rf /home/frappe/bench/sites/site1.local

  # Drop stale DB and users
  echo "-> Dropping stale DB and users..."
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "DROP DATABASE IF EXISTS frappe_hrms;" 2>/dev/null || true
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "SELECT CONCAT('DROP USER IF EXISTS \`',user,'\`@\`%\`;') FROM mysql.user WHERE user LIKE '\_%';" \
    -sN 2>/dev/null | mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" 2>/dev/null || true
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "FLUSH PRIVILEGES;" 2>/dev/null || true
  echo "-> Stale DB/users cleared."

  # Get HRMS app if not present
  if [ ! -d "/home/frappe/bench/apps/hrms" ]; then
    echo "-> Getting HRMS app..."
    su -s /bin/bash frappe -c "cd /home/frappe/bench && bench get-app https://github.com/frappe/hrms --branch version-15"
  fi

  # bench new-site
  echo "-> Running bench new-site with frappe_hrms db..."
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

  # Install HRMS
  echo "-> Installing HRMS..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local install-app hrms"

  # Migrate
  echo "-> Running migrate..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local migrate --skip-failing"

  echo "-> Setup done. Killing placeholder..."
  kill $PLACEHOLDER_PID 2>/dev/null || true
  sleep 2
fi

# --- Always patch site_config.json with correct DB host ---
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

# --- Recreate DB user with correct password from site_config.json ---
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
  # Drop user if exists (any host), recreate with % and correct password, grant all
  sql = \"DROP USER IF EXISTS '{u}'@'%'; CREATE USER '{u}'@'%' IDENTIFIED BY '{p}'; GRANT ALL PRIVILEGES ON \`{db}\`.* TO '{u}'@'%'; FLUSH PRIVILEGES;\".format(u=db_name, p=db_password, db=db_name)
  result = subprocess.run(
    ['mysql', '-h', host, '-P', port, '-uroot', '-p'+root_pass, '-e', sql],
    capture_output=True, text=True
  )
  if result.returncode == 0:
    print('DB user recreated OK: ' + db_name)
  else:
    print('ERROR recreating user: ' + result.stderr)
    exit(1)
"

# --- Set default site ---
echo "-> Setting default site..."
su -s /bin/bash frappe -c "cd /home/frappe/bench && bench use site1.local" || true

# --- Start bench serve ---
echo "-> Starting Frappe HRMS..."
exec su -s /bin/bash frappe -c "cd /home/frappe/bench && bench serve --port 8000"
