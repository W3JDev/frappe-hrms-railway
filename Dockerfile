FROM pipech/erpnext-docker-debian:version-15-latest

USER root

# Copy the auto-install script
COPY --chmod=0755 auto-start.sh /usr/local/bin/auto-start.sh

ENTRYPOINT ["/usr/local/bin/auto-start.sh"]
EXPOSE 8000
