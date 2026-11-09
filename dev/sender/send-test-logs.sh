#!/usr/bin/env bash
# Generates sample deploy events, a failed deploy run, and nginx access logs.
set -euo pipefail

apps=(demo-app other-app)

random_digest() {
  echo "sha256:$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

for app in "${apps[@]}"; do
  for _ in 1 2 3; do
    result=success
    if (( RANDOM % 4 == 0 )); then result=failure; fi
    logger -t deploy-event \
      "event=deploy app=$app image=ghcr.io/inglesp/$app digest=$(random_digest) result=$result duration_s=$(( RANDOM % 60 + 5 ))"
  done
done

logger -t systemd "deploy.service: Failed with result 'exit-code'."

mkdir -p /var/log/nginx
for _ in $(seq 200); do
  app=${apps[$(( RANDOM % ${#apps[@]} ))]}
  status=200
  if (( RANDOM % 10 == 0 )); then status=404; fi
  printf '{"vhost":"%s.example.org","status":%d,"bytes_sent":%d,"request_length":%d,"request_time":0.%03d,"method":"GET"}\n' \
    "$app" "$status" $(( RANDOM * 4 )) $(( RANDOM % 2000 + 200 )) $(( RANDOM % 1000 )) \
    >> "/var/log/nginx/$app-access.log"
done

echo "Sent test logs from $(hostname)."
