# /data is the app's volume in production. Creating it here, owned by 10001,
# means a fresh Docker volume (in compose.yaml) gets the same ownership.
FROM busybox:1.36.1 AS dirs
RUN mkdir -p /data && chown 10001:10001 /data

FROM grafana/loki:3.5.3
COPY config.yaml /etc/loki/config.yaml
COPY --from=dirs --chown=10001:10001 /data /data
# The base image already runs as 10001; stated here to make the contract explicit.
USER 10001
EXPOSE 8000
CMD ["-config.file=/etc/loki/config.yaml"]
