FROM powerdns/dnsdist-19:latest

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends bind9-host \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
