# Changes needed in infra-demo-infra

These are sketches against the repo as described in its README (`infra.md` here). They weren't written against its actual code, so names (variables, locals, recipe internals) will need adapting.

Names used below:

- `logs.opensafely.org`: Grafana (public, HTTPS)
- `logs-ingest.opensafely.org`: Alloy's syslog listener (port 6514 only)

## 1. `droplets.yml`

```yaml
logs:
  size: s-2vcpu-4gb
  log_server: true
  apps:
    loki:
      image: ghcr.io/inglesp/observability-loki
      image_tag: latest
      volume_size: 50
      dns_zone: false        # new: no zone
      proxy: false           # new: no domain, no nginx vhost, no TLS
      network: observability # new
      env: {}
    alloy:
      image: ghcr.io/inglesp/observability-alloy
      image_tag: latest
      volume_size: 5
      domain: logs-ingest.opensafely.org  # zone + A/AAAA records, for senders
      proxy: false
      network: observability
      checks: false          # new: zero-downtime deploys would clash on host port 6514
      docker_options:        # new
        - "-p 6514:6514"
      mounts:                # new: extra host paths, mounted read-only
        - /etc/web-app/log-tls:/etc/alloy/tls
      env: {}
    grafana:
      image: ghcr.io/inglesp/observability-grafana
      image_tag: latest
      volume_size: 5
      domain: logs.opensafely.org
      network: observability
      env:
        GF_SERVER_ROOT_URL: https://logs.opensafely.org/
```

The vault (`just vault-edit logs`) needs `alert_webhook_url`, plus:

```yaml
app_secrets:
  loki: {}
  alloy: {}
  grafana:
    GF_SECURITY_ADMIN_PASSWORD: ...  # openssl rand -hex 24
```

## 2. Ansible: new per-app options

All of these follow the existing "read the Dokku setting, and only run the command if it differs" pattern.

| option | Dokku commands |
| --- | --- |
| `proxy: false` | `dokku proxy:disable <app>`, and skip `domains:set`, `ports:set` and the letsencrypt steps. The deploy service skips `letsencrypt:enable` for these apps (Ansible can add a `proxy` field to `apps.json`). |
| `network` | `dokku network:create <net>` once, then `dokku network:set <app> attach-post-create <net>`. The app is then reachable from other apps on the network as `<app>.web`. |
| `checks: false` | `dokku checks:disable <app>` |
| `docker_options` | `dokku docker-options:add <app> deploy "<opt>"` (read the current ones with `docker-options:report <app> --docker-options-deploy`) |
| `mounts` | `dokku storage:mount <app> <host>:<container>:ro` (read with `storage:list <app>`) |

The OpenTofu `app` module skips the DNS zone when `dns_zone: false`.

## 3. OpenTofu

```hcl
# tls provider: hashicorp/tls

locals {
  log_ingest_name = "logs-ingest.opensafely.org"
  log_servers     = [for name, d in local.droplets : name if try(d.log_server, false)]
}

resource "tls_private_key" "log_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "log_ca" {
  private_key_pem       = tls_private_key.log_ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 24 * 365 * 5
  allowed_uses          = ["cert_signing", "crl_signing"]
  subject {
    common_name = "infra-demo logging CA"
  }
}

# Server cert for Alloy.
resource "tls_private_key" "log_server" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "log_server" {
  private_key_pem = tls_private_key.log_server.private_key_pem
  dns_names       = [local.log_ingest_name]
  subject {
    common_name = local.log_ingest_name
  }
}

resource "tls_locally_signed_cert" "log_server" {
  cert_request_pem      = tls_cert_request.log_server.cert_request_pem
  ca_private_key_pem    = tls_private_key.log_ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.log_ca.cert_pem
  validity_period_hours = 24 * 365
  early_renewal_hours   = 24 * 30
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

# One client cert per droplet.
resource "tls_private_key" "log_client" {
  for_each    = local.droplets
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "log_client" {
  for_each        = local.droplets
  private_key_pem = tls_private_key.log_client[each.key].private_key_pem
  subject {
    common_name = each.key
  }
}

resource "tls_locally_signed_cert" "log_client" {
  for_each              = local.droplets
  cert_request_pem      = tls_cert_request.log_client[each.key].cert_request_pem
  ca_private_key_pem    = tls_private_key.log_ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.log_ca.cert_pem
  validity_period_hours = 24 * 365
  early_renewal_hours   = 24 * 30
  allowed_uses          = ["digital_signature", "key_encipherment", "client_auth"]
}

output "log_tls" {
  sensitive = true
  value = {
    for name, _ in local.droplets : name => merge(
      {
        log_tls_ca   = tls_self_signed_cert.log_ca.cert_pem
        log_tls_cert = tls_locally_signed_cert.log_client[name].cert_pem
        log_tls_key  = tls_private_key.log_client[name].private_key_pem
      },
      contains(local.log_servers, name) ? {
        log_server_tls_cert = tls_locally_signed_cert.log_server.cert_pem
        log_server_tls_key  = tls_private_key.log_server.private_key_pem
      } : {}
    )
  }
}

# A second firewall on the log server, alongside the droplet module's own.
# It's at the root, rather than in the droplet module, because it refers to
# every droplet: in the module it would be a dependency cycle.
resource "digitalocean_firewall" "log_ingest" {
  for_each    = toset(local.log_servers)
  name        = "${each.key}-log-ingest"
  droplet_ids = [module.droplet[each.key].id]

  inbound_rule {
    protocol           = "tcp"
    port_range         = "6514"
    source_droplet_ids = [for name, d in module.droplet : d.id]
  }
}
```

None of this touches `user_data`, so no droplets are replaced.

## 4. `just sync-log-tls`

This writes each droplet's certs to `ansible/host_vars/<droplet>/log_tls.yml`, encrypted with the droplet's vault password. It only rewrites a file when its contents have changed, so re-running it doesn't create noisy diffs.

```just
sync-log-tls:
    #!/usr/bin/env bash
    set -euo pipefail
    tls=$(just tofu output -json log_tls)
    # Adapt: get the passwords however `vault-edit` does.
    passwords=$(just tofu output -json vault_passwords)
    pw=$(mktemp)
    trap 'rm -f "$pw"' EXIT
    chmod 600 "$pw"
    for droplet in $(jq -r 'keys[]' <<<"$tls"); do
      f="ansible/host_vars/$droplet/log_tls.yml"
      mkdir -p "$(dirname "$f")"
      new=$(jq --arg d "$droplet" '.[$d]' <<<"$tls")  # JSON is valid YAML
      jq -r --arg d "$droplet" '.[$d]' <<<"$passwords" > "$pw"
      if [ -f "$f" ] && [ "$(uv run ansible-vault view --vault-password-file "$pw" "$f")" = "$new" ]; then
        continue
      fi
      printf '%s\n' "$new" | uv run ansible-vault encrypt --vault-password-file "$pw" --output "$f" -
      echo "Updated $f"
    done
```

To rotate the certs, run `just tofu taint` on the cert resources (or wait for `early_renewal_hours`), then `just apply`, `just sync-log-tls`, and commit and push.

## 5. Ansible: `log_forwarding` role, on every droplet

```yaml
- name: Install rsyslog TLS support
  ansible.builtin.apt:
    name: rsyslog-gnutls

- name: Create rsyslog TLS directory
  ansible.builtin.file:
    path: /etc/rsyslog.d/tls
    state: directory
    mode: "0700"

- name: Write rsyslog client TLS files
  ansible.builtin.copy:
    dest: "/etc/rsyslog.d/tls/{{ item.name }}"
    content: "{{ item.content }}"
    mode: "0600"
  loop:
    - { name: ca.crt, content: "{{ log_tls_ca }}" }
    - { name: client.crt, content: "{{ log_tls_cert }}" }
    - { name: client.key, content: "{{ log_tls_key }}" }
  no_log: true
  notify: Restart rsyslog

- name: Configure forwarding
  ansible.builtin.template:
    src: 90-forward.conf.j2
    dest: /etc/rsyslog.d/90-forward.conf
    validate: rsyslogd -N1 -f %s
  notify: Restart rsyslog

# On the log server only: TLS files for Alloy, readable by its container's UID.
- name: Write Alloy's TLS files
  when: log_server | default(false)
  block:
    - ansible.builtin.file:
        path: /etc/web-app/log-tls
        state: directory
        owner: "10001"
        mode: "0700"
    - ansible.builtin.copy:
        dest: "/etc/web-app/log-tls/{{ item.name }}"
        content: "{{ item.content }}"
        owner: "10001"
        mode: "0600"
      loop:
        - { name: ca.crt, content: "{{ log_tls_ca }}" }
        - { name: server.crt, content: "{{ log_server_tls_cert }}" }
        - { name: server.key, content: "{{ log_server_tls_key }}" }
      no_log: true
      # Alloy reads its certs at startup.
      notify: Restart alloy  # dokku ps:restart alloy
```

`90-forward.conf.j2` is `dev/sender/90-forward.conf` from this repo with:

- `target` and `StreamDriverPermittedPeers` set to `logs-ingest.opensafely.org`
- `StreamDriver.*File` set to `/etc/rsyslog.d/tls/...`, as it already is

Two caveats:

- `validate: rsyslogd -N1 -f %s` checks the snippet on its own, so if that fails because of how the snippet depends on the main config, validate the whole config after writing instead.
- The log server forwards to itself through its public name. That works because the cloud firewall doesn't filter a droplet's traffic to itself. If it turns out not to, use `127.0.0.1` there, and add `DNS:localhost` and `IP:127.0.0.1` to the server cert.

Ubuntu's rsyslog already reads journald (through imuxsock), so the `deploy` and `systemd` lines arrive with no extra config.

## 6. nginx log format

`/etc/nginx/conf.d/00-bytes-json.conf`:

```nginx
# No client IPs, URLs or query strings: just enough to count bytes.
log_format bytes_json escape=json
  '{"vhost":"$server_name","status":$status,"bytes_sent":$bytes_sent,'
  '"request_length":$request_length,"request_time":$request_time,'
  '"method":"$request_method"}';
```

Then, with the usual read-then-set check against `dokku nginx:report --global`:

```sh
dokku nginx:set --global access-log-format bytes_json
dokku proxy:build-config --all
```

Dokku keeps writing `/var/log/nginx/<app>-access.log`, which the rsyslog `imfile` input tails. The files' logrotate rules don't need changing, since imfile follows rotation.

## 7. Deploy script

Around each actual deploy, that is when the digest has changed:

```bash
start=$SECONDS
if dokku git:from-image "$app" "$image@$digest"; then
  result=success
else
  result=failure
fi
logger -t deploy-event \
  "event=deploy app=$app image=$image digest=$digest result=$result duration_s=$(( SECONDS - start ))"
```

Keep the existing failure handling, so one app's failure still doesn't stop the others and the run still shows as failed.

## 8. Rollout

1. Merge this repo to `main`, so CI publishes the three images. Make the GHCR packages public, or give the droplets a pull credential.
2. In infra-demo-infra, add the OpenTofu changes and the `logs` droplet, delegate both zones, and follow the "Add a droplet" runbook. Run `just sync-log-tls` after `set-vault-password` and before committing.
3. Once the log droplet is up, push the `log_forwarding` role, nginx and deploy script changes, so that every droplet starts forwarding.
4. Update the "Add a droplet" runbook. A new droplet's first `ansible-pull` needs its client cert, so `just set-vault-password <droplet>` should also target that droplet's `tls_private_key.log_client`, `tls_cert_request.log_client` and `tls_locally_signed_cert.log_client`. Then run `just sync-log-tls` before committing.
