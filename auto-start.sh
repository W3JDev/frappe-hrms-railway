#!/bin/bash

echo "-> Waiting for external MariaDB at ${DB_HOST}:${DB_PORT}..."
until mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; do
  echo "   MariaDB not ready, retrying in 3s..."
  sleep 3
done
echo "-> MariaDB is ready!"

# Patch site_config.json so Frappe connects to the Railway MariaDB, not 127.0.0.1
SITE_CONFIG="/home/frappe/bench/sites/site1.local/site_config.json"
if [ -f "$SITE_CONFIG" ]; then
  echo "-> Patching site_config.json with db_host=${DB_HOST}..."
  python3 -c "
import json, os
config_path = '$SITE_CONFIG'
with open(config_path) as f:
    config = json.load(f)
config['db_host'] = os.environ.get('DB_HOST', 'mariadb.railway.internal')
config['db_port'] = int(os.environ.get('DB_PORT', 3306))
with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
print('Patched db_name:', config.get('db_name'), 'db_host:', config.get('db_host'))
"
  echo "-> site_config.json patched!"

  # Extract credentials from site_config
  DB_NAME=$(python3 -c "import json; c=json.load(open('$SITE_CONFIG')); print(c['db_name'])")
  DB_PASS=$(python3 -c "import json; c=json.load(open('$SITE_CONFIG')); print(c['db_password'])")
  echo "-> Granting access for DB user '${DB_NAME}' from any host..."

  # Drop old localhost-bound user, re-create with % wildcard
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" <<-SQL
    DROP USER IF EXISTS '${DB_NAME}'@'localhost';
    CREATE USER IF NOT EXISTS '${DB_NAME}'@'%' IDENTIFIED BY '${DB_PASS}';
    GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_NAME}'@'%';
    FLUSH PRIVILEGES;
SQL
  echo "-> DB user grant done!"
fi

SETUP_FLAG="/home/frappe/bench/sites/.hrms_installed"

if [ ! -f "$SETUP_FLAG" ]; then
  echo "-> Installing HRMS into site1.local..."

  if [ ! -d "/home/frappe/bench/apps/hrms" ]; then
    echo "-> Downloading HRMS app..."
    su -s /bin/bash frappe -c "cd /home/frappe/bench && bench get-app https://github.com/frappe/hrms --branch version-15"
  else
    echo "-> HRMS app already exists, skipping get-app"
  fi

  echo "-> Installing HRMS on site1.local..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local install-app hrms"

  echo "-> Running migrations..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local migrate --skip-failing"

  touch "$SETUP_FLAG"
  echo "-> HRMS installed successfully!"
fi

echo "-> Starting ERPNext + HRMS..."
exec su -s /bin/bash frappe -c "cd /home/frappe/bench && bench start"
