#!/bin/bash
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

SETUP_FLAG="/home/frappe/bench/sites/.setup_complete"

if [ ! -f "$SETUP_FLAG" ]; then
  echo "-> First boot: setting up site from scratch..."

  # --- 2. Drop old stale site if exists ---
  if [ -d "/home/frappe/bench/sites/site1.local" ]; then
    echo "-> Removing stale site1.local directory..."
    rm -rf /home/frappe/bench/sites/site1.local
  fi

  # --- 3. Drop and recreate DB + user cleanly using root ---
  echo "-> Dropping old DB/user if exists..."
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" <<EOF
DROP DATABASE IF EXISTS frappe_hrms;
DROP USER IF EXISTS 'frappe_hrms'@'%';
CREATE DATABASE frappe_hrms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'frappe_hrms'@'%' IDENTIFIED BY '${RFP_SITE_ADMIN_PASSWORD}';
GRANT ALL PRIVILEGES ON frappe_hrms.* TO 'frappe_hrms'@'%';
FLUSH PRIVILEGES;
EOF
  echo "-> DB and user ready!"

  # --- 4. Get HRMS app if not present ---
  if [ ! -d "/home/frappe/bench/apps/hrms" ]; then
    echo "-> Downloading HRMS app..."
    su -s /bin/bash frappe -c "cd /home/frappe/bench && bench get-app https://github.com/frappe/hrms --branch version-15"
  else
    echo "-> HRMS app already present."
  fi

  # --- 5. Create site with explicit db-name and db-password ---
  echo "-> Creating site1.local via bench new-site..."
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

  # --- 6. Install HRMS ---
  echo "-> Installing HRMS app on site1.local..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local install-app hrms"

  # --- 7. Run migrations ---
  echo "-> Running migrations..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local migrate --skip-failing"

  touch "$SETUP_FLAG"
  echo "-> Site setup complete!"
else
  echo "-> Site already set up, skipping new-site."
fi

# --- 8. Start bench ---
echo "-> Starting ERPNext + HRMS..."
exec su -s /bin/bash frappe -c "cd /home/frappe/bench && bench start"
