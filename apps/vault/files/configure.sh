#!/bin/sh
# Configures the SSH CA in Vault. templates/config-job.yaml runs this after
# every Argo CD sync. Every step is idempotent.
#
# The Job logs in with its ServiceAccount (Kubernetes auth). That auth method,
# and the first copy of the vault-config policy, are set up once by hand with
# the root token. See README.md.
set -eu

CONFIG=/config
USERPASS=/userpass/password

log() { echo "$(date -Iseconds) $*"; }

# A preset VAULT_TOKEN skips the login, for running this by hand.
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login \
    role=vault-config jwt=@/var/run/secrets/vault/token)
  export VAULT_TOKEN
  trap 'vault token revoke -self >/dev/null 2>&1 || true' EXIT
fi

# The Job may rewrite its own policy, so the repo copy is the source of truth.
vault policy write vault-config "$CONFIG/vault-config.hcl" >/dev/null
vault policy write ssh-operator "$CONFIG/ssh-operator.hcl" >/dev/null
log "policies written"

enable_secrets() {
  if ! vault secrets list | grep -q "^$1/ "; then
    vault secrets enable -path="$1" ssh >/dev/null
    log "enabled secrets engine $1"
  fi
}

enable_auth() {
  if ! vault auth list | grep -q "^$1/ "; then
    vault auth enable "$1" >/dev/null
    log "enabled auth method $1"
  fi
}

# Generate the CA key inside Vault, once. Writing config/ca again would fail,
# and replacing the key would invalidate every cert and every trust entry.
ensure_ca() {
  if ! vault read -field=public_key "$1/config/ca" >/dev/null 2>&1; then
    vault write "$1/config/ca" generate_signing_key=true key_type=ed25519 >/dev/null
    log "generated CA key for $1"
  fi
}

# User certs. The only principal is `me`, so this CA cannot sign a login as
# root or anyone else.
enable_secrets ssh-client-signer
ensure_ca ssh-client-signer
vault write ssh-client-signer/roles/me - >/dev/null <<'EOF'
{
  "key_type": "ca",
  "allow_user_certificates": true,
  "allowed_users": "me",
  "default_user": "me",
  "allowed_extensions": "permit-pty,permit-port-forwarding,permit-agent-forwarding",
  "default_extensions": {
    "permit-pty": "",
    "permit-port-forwarding": "",
    "permit-agent-forwarding": ""
  },
  "ttl": "8h",
  "max_ttl": "24h"
}
EOF
log "wrote role ssh-client-signer/roles/me"

# Host certs. The mount's max TTL defaults to 32 days, which would cap the
# one-year role TTL, so raise it.
enable_secrets ssh-host-signer
ensure_ca ssh-host-signer
vault secrets tune -max-lease-ttl=8760h ssh-host-signer >/dev/null
vault write ssh-host-signer/roles/host - >/dev/null <<'EOF'
{
  "key_type": "ca",
  "allow_host_certificates": true,
  "allowed_domains": "k8s-1,k8s-2,k8s-3,k8s-4,192.168.1.40,192.168.1.41,192.168.1.42,192.168.1.43",
  "allow_bare_domains": true,
  "allow_subdomains": false,
  "ttl": "8760h",
  "max_ttl": "8760h"
}
EOF
log "wrote role ssh-host-signer/roles/host"

# Logins for the operator. Each step is skipped until its input is committed,
# so the Job still succeeds partway through the bootstrap.
if [ -s "$USERPASS" ]; then
  enable_auth userpass
  vault write auth/userpass/users/me password=@"$USERPASS" \
    token_policies=ssh-operator token_ttl=1h token_max_ttl=8h >/dev/null
  log "wrote userpass user me"
else
  log "skipped userpass: no vault-userpass Secret yet"
fi

if [ -s "$CONFIG/client-ca.crt" ]; then
  enable_auth cert
  vault write auth/cert/certs/me certificate=@"$CONFIG/client-ca.crt" \
    allowed_common_names=me \
    token_policies=ssh-operator token_ttl=1h token_max_ttl=8h >/dev/null
  log "wrote cert role me"
else
  log "skipped cert auth: files/client-ca.crt is empty"
fi

log "done"
