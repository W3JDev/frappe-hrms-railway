FROM pipech/erpnext-docker-debian:version-15-latest

USER root

# Install HRMS during Docker build:
# 1. Start MariaDB (needed for bench install-app)
# 2. Get HRMS app from GitHub
# 3. Install into site1.local
# 4. Migrate database
# 5. Stop MariaDB cleanly
RUN service mariadb start \
    && sleep 8 \
    && su frappe -c "cd /home/frappe/bench && bench get-app https://github.com/frappe/hrms --branch version-15" \
    && su frappe -c "cd /home/frappe/bench && bench --site site1.local install-app hrms" \
    && su frappe -c "cd /home/frappe/bench && bench --site site1.local migrate --skip-failing" \
    && service mariadb stop \
    && sleep 3 \
    && echo "✓ HRMS installed into site1.local"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
EXPOSE 8000
