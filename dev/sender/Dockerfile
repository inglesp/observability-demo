# A stand-in for a fleet droplet: rsyslog forwarding to Alloy over mutual TLS.
FROM debian:bookworm-slim

# There's no kernel log in a container, so imklog is disabled.
RUN apt-get update \
 && apt-get install -y --no-install-recommends rsyslog rsyslog-gnutls ca-certificates openssl \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i '/imklog/s/^/#/' /etc/rsyslog.conf \
 && mkdir -p /var/spool/rsyslog /var/log/nginx

COPY 90-forward.conf /etc/rsyslog.d/90-forward.conf
COPY --chmod=755 send-test-logs.sh /usr/local/bin/send-test-logs

CMD ["rsyslogd", "-n", "-iNONE"]
