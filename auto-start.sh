#!/bin/bash

echo "-> Waiting for external MariaDB at ${DB_HOST}:${DB_PORT}..."
until mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; do
  echo "   MariaDB not ready, retrying in 3s..."
  sleep 3
done
echo "-> MariaDB is ready!"

SETUP_FLAG="/home/frappe/bench/sites/.hrms_installed"

if [ ! -f "$SETUP_FLAG" ]; then
  echo "-> Installing HRMS into site1.local..."

  # Get HRMS app only if not already downloaded
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
