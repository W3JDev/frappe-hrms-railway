#!/bin/sh
set -e

SETUP_FLAG="/home/frappe/bench/sites/.setup_complete"

if [ ! -f "$SETUP_FLAG" ]; then
    echo "============================================="
    echo "-> First boot: Running ERPNext + HRMS setup"
    echo "============================================="

    echo "-> Create empty common site config"
    echo "{}" > /home/frappe/bench/sites/common_site_config.json

    echo "-> Create new site with ERPNext"
    su frappe -c "bench new-site ${RFP_DOMAIN_NAME} \
        --admin-password ${RFP_SITE_ADMIN_PASSWORD} \
        --no-mariadb-socket \
        --db-root-password ${RFP_DB_ROOT_PASSWORD} \
        --install-app erpnext"

    echo "-> Install HRMS"
    su frappe -c "bench --site ${RFP_DOMAIN_NAME} install-app hrms"

    echo "-> Set default site"
    su frappe -c "bench use ${RFP_DOMAIN_NAME}"

    echo "-> Enable scheduler"
    su frappe -c "bench enable-scheduler"

    echo "-> Migrate"
    su frappe -c "bench --site ${RFP_DOMAIN_NAME} migrate"

    touch "$SETUP_FLAG"
    echo "-> Setup complete!"
fi

echo "-> Starting ERPNext server"
exec /usr/local/bin/railway-cmd.sh
