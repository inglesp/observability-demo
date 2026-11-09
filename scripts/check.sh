#!/usr/bin/env bash
# Builds the images and checks their config. Used by `just check` and CI.
set -euo pipefail

cd "$(dirname "$0")/.."

for image in loki alloy grafana; do
  docker build -t "observability-$image:check" "$image"
done

echo "Checking Loki config..."
docker run --rm observability-loki:check -config.file=/etc/loki/config.yaml -verify-config

echo "Checking Alloy config..."
diff -u alloy/config.alloy <(docker run --rm --entrypoint /bin/alloy observability-alloy:check fmt /etc/alloy/config.alloy) \
  || { echo "alloy/config.alloy isn't formatted (or doesn't parse): see the diff above"; exit 1; }

echo "Checking dashboards are valid JSON..."
for f in grafana/dashboards/*.json; do
  python3 -m json.tool "$f" > /dev/null
done

echo "All checks passed."
