FROM pipech/erpnext-docker-debian:version-15-latest

USER root

# Start MariaDB, install HRMS into the existing site1.local, then stop
RUN service mariadb start && sleep 5 \
    && su frappe -c "cd /home/frappe/bench && bench get-app https://github.com/frappe/hrms --branch version-15" \
    && su frappe -c "cd /home/frappe/bench && bench --site site1.local install-app hrms" \
    && su frappe -c "cd /home/frappe/bench && bench --site site1.local migrate" \
    && service mariadb stop \
    && echo "HRMS installed successfully"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
EXPOSE 8000
