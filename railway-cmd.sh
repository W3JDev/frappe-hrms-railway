#!/bin/sh
set -e

echo "-> Patching DB host FIRST in common_site_config and site_config"
echo "{\"db_host\": \"${DB_HOST}\"}" > /home/frappe/bench/sites/common_site_config.json

SITE_CONFIG="/home/frappe/bench/sites/${RFP_DOMAIN_NAME}/site_config.json"
if [ -f "$SITE_CONFIG" ]; then
  python3 -c "
import json, os
with open('$SITE_CONFIG', 'r') as f:
    cfg = json.load(f)
cfg['db_host'] = os.environ['DB_HOST']
with open('$SITE_CONFIG', 'w') as f:
    json.dump(cfg, f, indent=2)
print('Patched db_host in site_config.json')
"
fi

echo "-> Clearing cache"
su frappe -c "bench execute frappe.cache_manager.clear_global_cache" || echo "Cache clear skipped"

echo "-> Bursting env into config"
envsubst '$RFP_DOMAIN_NAME' < /home/$systemUser/temp_nginx.conf > /etc/nginx/conf.d/default.conf
envsubst '$PATH,$HOME,$NVM_DIR,$NODE_VERSION' < /home/$systemUser/temp_supervisor.conf > /home/$systemUser/supervisor.conf

echo "-> Starting nginx"
nginx

echo "-> Starting supervisor"
/usr/bin/supervisord -c /home/$systemUser/supervisor.conf
