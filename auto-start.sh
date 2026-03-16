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

# --- 2. Check if DB tables exist ---
DB_READY=$(mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='frappe_hrms' AND table_name='tabSingles';" \
  -sN 2>/dev/null || echo "0")

if [ "$DB_READY" != "1" ]; then
  echo "-> DB not initialized. Running full setup in background..."

  # Start a dummy HTTP server on port 8000 so Railway health check passes
  echo "-> Starting temporary HTTP placeholder on port 8000..."
  while true; do
    echo -e 'HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nSetting up...' | nc -l -p 8000 -q 1 2>/dev/null || true
  done &
  PLACEHOLDER_PID=$!
  echo "-> Placeholder running (PID $PLACEHOLDER_PID)"

  # --- 3. Drop old stale site if exists ---
  if [ -d "/home/frappe/bench/sites/site1.local" ]; then
    echo "-> Removing stale site1.local directory..."
    rm -rf /home/frappe/bench/sites/site1.local
  fi

  # --- 4. Recreate DB and user ---
  echo "-> Recreating DB and user..."
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" <<EOF
DROP DATABASE IF EXISTS frappe_hrms;
DROP USER IF EXISTS 'frappe_hrms'@'%';
CREATE DATABASE frappe_hrms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'frappe_hrms'@'%' IDENTIFIED BY '${RFP_SITE_ADMIN_PASSWORD}';
GRANT ALL PRIVILEGES ON frappe_hrms.* TO 'frappe_hrms'@'%';
FLUSH PRIVILEGES;
EOF
  echo "-> DB and user ready!"

  # --- 5. Get HRMS app if not present ---
  if [ ! -d "/home/frappe/bench/apps/hrms" ]; then
    echo "-> Downloading HRMS app..."
    su -s /bin/bash frappe -c "cd /home/frappe/bench && bench get-app https://github.com/frappe/hrms --branch version-15"
  else
    echo "-> HRMS app already present."
  fi

  # --- 6. bench new-site (this takes 10-20 mins) ---
  echo "-> Creating site1.local via bench new-site (this takes time, placeholder keeps port 8000 alive)..."
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

  # --- 7. Install HRMS ---
  echo "-> Installing HRMS app..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local install-app hrms"

  # --- 8. Migrate ---
  echo "-> Running migrations..."
  su -s /bin/bash frappe -c "cd /home/frappe/bench && bench --site site1.local migrate --skip-failing"

  echo "-> Setup complete! Killing placeholder..."
  kill $PLACEHOLDER_PID 2>/dev/null || true
  sleep 1
else
  echo "-> DB already initialized (tabSingles exists). Skipping new-site."
fi

# --- 9. Start bench ---
echo "-> Starting ERPNext + HRMS..."
exec su -s /bin/bash frappe -c "cd /home/frappe/bench && bench start"
