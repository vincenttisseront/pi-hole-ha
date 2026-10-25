FROM alpine:3.22

RUN apk add --no-cache \
        keepalived \
        bind-tools \
        iproute2 \
        gettext \
    && mkdir -p /etc/keepalived /usr/local/bin

COPY keepalived.conf.tmpl /etc/keepalived/keepalived.conf.tmpl
COPY check-dns.sh /usr/local/bin/check-dns.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# keepalived refuse un script modifiable par le groupe ou les autres
# lorsque enable_script_security est actif.
RUN chmod 755 /usr/local/bin/check-dns.sh /usr/local/bin/entrypoint.sh \
    && chown root:root /usr/local/bin/check-dns.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
