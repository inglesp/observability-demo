default:
    @just --list

# Build the images and check their config
check:
    bash scripts/check.sh

# Generate a throwaway CA, server cert and client certs for the local stack
gen-test-certs:
    #!/usr/bin/env bash
    set -euo pipefail
    d=dev/certs
    rm -rf "$d"
    mkdir -p "$d/server" "$d/client" "$d/rogue"
    ec="-newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes"

    # CA
    openssl req -x509 $ec -days 30 -subj "/CN=dev logging CA" \
      -keyout "$d/ca.key" -out "$d/ca.crt" 2>/dev/null

    # Server cert for Alloy, valid for the name the sender connects to.
    openssl req $ec -subj "/CN=alloy" -keyout "$d/server/server.key" -out "$d/server.csr" 2>/dev/null
    openssl x509 -req -in "$d/server.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial -days 30 \
      -extfile <(printf "subjectAltName=DNS:alloy,DNS:localhost\nextendedKeyUsage=serverAuth\n") \
      -out "$d/server/server.crt" 2>/dev/null
    cp "$d/ca.crt" "$d/server/ca.crt"

    # Client cert for the sender.
    openssl req $ec -subj "/CN=dev-sender" -keyout "$d/client/client.key" -out "$d/client.csr" 2>/dev/null
    openssl x509 -req -in "$d/client.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial -days 30 \
      -extfile <(printf "extendedKeyUsage=clientAuth\n") \
      -out "$d/client/client.crt" 2>/dev/null
    cp "$d/ca.crt" "$d/client/ca.crt"

    # A self-signed client cert that isn't from the CA, for checking that Alloy rejects it.
    openssl req -x509 $ec -days 30 -subj "/CN=rogue" \
      -keyout "$d/rogue/client.key" -out "$d/rogue/client.crt" 2>/dev/null

    rm -f "$d"/*.csr "$d"/*.srl
    # The containers run as other UIDs (Alloy as 10001), so the keys must be
    # readable by them. These are throwaway dev keys only.
    chmod 644 "$d"/server/* "$d"/client/* "$d"/rogue/*
    echo "Wrote test certs to $d"

# Start the local stack (Grafana: http://localhost:3000, admin/admin)
up:
    docker compose up --build -d

# Stop the local stack
down:
    docker compose down

# Stop the local stack and delete its data
reset:
    docker compose down -v

# Send sample deploy events and nginx access logs from the test sender
send-test-logs:
    docker compose exec sender send-test-logs

# Check that Alloy accepts the CA-signed client cert, and rejects no cert and a rogue cert
check-mtls:
    #!/usr/bin/env bash
    set -uo pipefail
    d=dev/certs
    # TLS 1.2, so that a rejected client cert fails the handshake itself
    # (with TLS 1.3 the server's rejection arrives after the client thinks
    # the handshake is done, which s_client may not wait for).
    try() {
      echo | openssl s_client -tls1_2 -connect localhost:6514 -servername alloy -verify_return_error \
        -CAfile "$d/ca.crt" "$@" 2>&1 >/dev/null | grep -qiE "alert|error" && echo rejected || echo accepted
    }
    echo "CA-signed client cert: $(try -cert $d/client/client.crt -key $d/client/client.key) (want: accepted)"
    echo "no client cert:        $(try) (want: rejected)"
    echo "rogue client cert:     $(try -cert $d/rogue/client.crt -key $d/rogue/client.key) (want: rejected)"

# Follow the logs of the local stack
logs *services:
    docker compose logs -f {{services}}
