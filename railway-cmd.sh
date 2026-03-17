#!/bin/sh
set -e

echo "-> Clearing cache"
su frappe -c "bench execute frappe.cache_manager.clear_global_cache"

echo "-> Ensure DB host is set in common site config"
echo "{\"db_host\": \"${DB_HOST}\"}" > /home/frappe/bench/sites/common_site_config.json

echo "-> Bursting env into config"
envsubst '$RFP_DOMAIN_NAME' < /home/$systemUser/temp_nginx.conf > /etc/nginx/conf.d/default.conf
envsubst '$PATH,$HOME,$NVM_DIR,$NODE_VERSION' < /home/$systemUser/temp_supervisor.conf > /home/$systemUser/supervisor.conf

echo "-> Starting nginx"
nginx

echo "-> Starting supervisor"
/usr/bin/supervisord -c /home/$systemUser/supervisor.conf
