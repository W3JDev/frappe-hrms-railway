FROM pipech/erpnext-docker-debian:version-15-latest

USER root

# Install HRMS app into the bench
USER frappe
WORKDIR /home/frappe/bench
RUN bench get-app https://github.com/frappe/hrms --branch version-15

USER root
COPY --chmod=0755 auto-start.sh /usr/local/bin/auto-start.sh

EXPOSE 8000

CMD ["/usr/local/bin/auto-start.sh"]
