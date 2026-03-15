#!/bin/bash

echo "-> Starting MariaDB..."
sudo service mariadb start
sleep 8

# Fix MariaDB root access (image uses unix_socket auth by default)
sudo mysql -u root --skip-password -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'frappe123'; FLUSH PRIVILEGES;" 2>/dev/null || \
sudo mysqladmin -u root password 'frappe123' 2>/dev/null || true

SETUP_FLAG="/home/frappe/bench/sites/.hrms_installed"

if [ ! -f "$SETUP_FLAG" ]; then
    echo "============================================="
    echo "-> Installing HRMS into site1.local..."
    echo "============================================="
    
    su frappe -c "
        source /home/frappe/.nvm/nvm.sh
        cd /home/frappe/bench
        /home/frappe/.local/bin/bench get-app https://github.com/frappe/hrms --branch version-15
        /home/frappe/.local/bin/bench --site site1.local install-app hrms
        /home/frappe/.local/bin/bench --site site1.local migrate --skip-failing
    "
    
    touch "$SETUP_FLAG"
    echo "-> HRMS installed!"
fi

echo "-> Starting ERPNext..."
exec su frappe -c "source /home/frappe/.nvm/nvm.sh && cd /home/frappe/bench && /home/frappe/.local/bin/bench start"
