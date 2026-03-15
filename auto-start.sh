#!/bin/bash
set -e

SETUP_FLAG="/home/frappe/bench/sites/.setup_complete"

echo "-> Starting MariaDB..."
sudo service mariadb start
sleep 5

if [ ! -f "$SETUP_FLAG" ]; then
    echo "============================================="
    echo "-> First boot: Creating ERPNext + HRMS site"
    echo "============================================="

    # Set MariaDB root password
    sudo mysqladmin -u root password "frappe123" 2>/dev/null || true

    echo "-> Create new site"
    cd /home/frappe/bench
    bench new-site frontend \
        --admin-password admin123 \
        --db-root-password frappe123 \
        --install-app erpnext

    echo "-> Install HRMS"
    bench --site frontend install-app hrms

    echo "-> Enable scheduler"
    bench use frontend
    bench enable-scheduler

    echo "-> Migrate"
    bench --site frontend migrate

    touch "$SETUP_FLAG"
    echo "-> Setup complete!"
fi

echo "-> Starting ERPNext..."
exec bench start
