FROM pipech/erpnext-docker-debian:version-15-latest

USER root
COPY --chmod=0755 auto-start.sh /usr/local/bin/auto-start.sh

SHELL ["/bin/bash", "-c"]
ENTRYPOINT ["/bin/bash", "/usr/local/bin/auto-start.sh"]
EXPOSE 8000
