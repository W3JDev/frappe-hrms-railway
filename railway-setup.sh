#!/bin/bash
set -e

# -> Run entrypoint
# somehow when specify custom cmd in railway,
# it doesn't run entrypoint first, so we need to run it here.
sudo /usr/local/bin/railway-entrypoint.sh

echo "-> Write DB host into common site config"
echo "{\"db_host\": \"${DB_HOST}\"}" > /home/frappe/bench/sites/common_site_config.json

echo "-> Create new site with HRMS"
bench new-site ${RFP_DOMAIN_NAME} --admin-password ${RFP_SITE_ADMIN_PASSWORD} --no-mariadb-socket --db-root-password ${RFP_DB_ROOT_PASSWORD} --db-host ${DB_HOST} --install-app hrms
bench use ${RFP_DOMAIN_NAME}

echo "-> Enable scheduler"
bench enable-scheduler
