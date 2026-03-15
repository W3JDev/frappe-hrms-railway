#!/bin/bash

echo "-> Starting MariaDB..."
sudo service mariadb start
sleep 8

SETUP_FLAG="/home/frappe/bench/sites/.hrms_installed"

if [ ! -f "$SETUP_FLAG" ]; then
    echo "-> Installing HRMS into site1.local..."
    cd /home/frappe/bench
    /home/frappe/.local/bin/bench get-app https://github.com/frappe/hrms --branch version-15
    /home/frappe/.local/bin/bench --site site1.local install-app hrms
    /home/frappe/.local/bin/bench --site site1.local migrate --skip-failing
    touch "$SETUP_FLAG"
    echo "-> HRMS installed!"
fi

echo "-> Starting ERPNext..."
cd /home/frappe/bench
exec /home/frappe/.local/bin/bench start
