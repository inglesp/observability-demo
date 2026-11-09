FROM busybox:1.36.1 AS dirs
RUN mkdir -p /data/plugins && chown -R 10001:10001 /data

FROM grafana/grafana:12.1.0

ENV GF_SERVER_HTTP_PORT=8000 \
    GF_PATHS_DATA=/data \
    GF_PATHS_PLUGINS=/data/plugins \
    GF_PATHS_PROVISIONING=/etc/grafana/provisioning \
    GF_LOG_MODE=console \
    GF_USERS_ALLOW_SIGN_UP=false \
    GF_AUTH_ANONYMOUS_ENABLED=false \
    GF_SECURITY_COOKIE_SECURE=true \
    GF_ANALYTICS_REPORTING_ENABLED=false \
    GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false \
    LOKI_URL=http://loki.web:8000

COPY provisioning /etc/grafana/provisioning
COPY dashboards /etc/grafana/dashboards
COPY --from=dirs --chown=10001:10001 /data /data

USER 10001
EXPOSE 8000
