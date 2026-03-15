FROM pipech/erpnext-docker-debian:version-15-latest AS builder

USER $systemUser
WORKDIR /home/$systemUser/$benchFolderName

RUN echo "-> Start builder" \
    && rm -rf /home/$systemUser/$benchFolderName/sites/site1.local \
    && sed -i 's/socket\.AF_INET, socket\.SOCK_STREAM/socket.AF_INET6, socket.SOCK_STREAM/g' /home/frappe/bench/apps/frappe/frappe/utils/connections.py \
    && bench get-app https://github.com/frappe/hrms --branch version-15 \
    && echo "-> Builder done!"

FROM frappe/bench:v5.22.9

ENV systemUser=frappe
ENV benchFolderName=bench

COPY --from=builder --chown=$systemUser /home/$systemUser/$benchFolderName /home/$systemUser/$benchFolderName

COPY temp_nginx.conf /home/$systemUser/temp_nginx.conf
COPY temp_supervisor.conf /home/$systemUser/temp_supervisor.conf

USER root
WORKDIR /home/$systemUser/$benchFolderName

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y nginx supervisor \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default \
    && su $systemUser -c "bench build" \
    && su $systemUser -c "cp -r /home/$systemUser/$benchFolderName/sites /home/$systemUser/$benchFolderName/built_sites"

COPY --chown=$systemUser --chmod=0755 railway-setup.sh /home/$systemUser/$benchFolderName/railway-setup.sh
COPY --chown=$systemUser --chmod=0755 railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY --chown=$systemUser --chmod=0755 railway-cmd.sh /usr/local/bin/railway-cmd.sh
COPY --chown=$systemUser --chmod=0755 auto-start.sh /usr/local/bin/auto-start.sh

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["/usr/local/bin/auto-start.sh"]

EXPOSE 80
