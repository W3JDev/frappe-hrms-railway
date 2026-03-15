#!/bin/bash
set -e

echo "-> Starting MariaDB..."
sudo service mariadb start
sleep 8

SETUP_FLAG="/home/frappe/bench/sites/.hrms_installed"

if [ ! -f "$SETUP_FLAG" ]; then
    echo "============================================="
    echo "-> Installing HRMS into site1.local..."
    echo "============================================="
    cd /home/frappe/bench
    bench get-app https://github.com/frappe/hrms --branch version-15
    bench --site site1.local install-app hrms
    bench --site site1.local migrate --skip-failing
    touch "$SETUP_FLAG"
    echo "-> HRMS installed successfully!"
fi

echo "-> Starting ERPNext..."
cd /home/frappe/bench
exec bench start
