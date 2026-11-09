FROM busybox:1.36.1 AS dirs
RUN mkdir -p /data && chown 10001:10001 /data

FROM grafana/alloy:v1.10.0
COPY config.alloy /etc/alloy/config.alloy
COPY --from=dirs --chown=10001:10001 /data /data
USER 10001
# 8000: Alloy's HTTP UI and API (not exposed publicly).
# 6514: syslog over TLS, published on the host with docker-options.
EXPOSE 8000 6514
CMD ["run", "--server.http.listen-addr=0.0.0.0:8000", "--storage.path=/data", "/etc/alloy/config.alloy"]
