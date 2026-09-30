# Vault

HashiCorp Vault, used as the SSH certificate authority for the cluster nodes.
One standalone pod on integrated Raft storage, reachable at
`https://vault.cikli.com` (192.168.1.97).

| File | Purpose |
| --- | --- |
| `values.yaml` | Vault config and the `unsealer` sidecar. |
| `templates/certificate.yaml` | Vault's TLS cert from `letsencrypt-prod`. |
| `templates/network.yaml` | TLS passthrough Gateway and TLSRoute on 192.168.1.97. |
| `templates/sealed-secret-unseal-key.yaml` | The unseal key. Added once, after init. |
| `templates/config-job.yaml` | PostSync Job that runs `files/configure.sh`. |
| `templates/sealed-secret-userpass.yaml` | Password for the `me` userpass login. |
| `files/configure.sh` | Sets up the SSH CAs, roles and logins. Idempotent. |
| `files/vault-config.hcl` | Policy for the config Job. |
| `files/ssh-operator.hcl` | Policy for your logins: sign user and host certs. |
| `files/client-ca.crt` | CA that the `cert` login trusts. The key is on your Mac. |
| `ansible/` | Makes the nodes trust the CA and installs host certs. |

## SSH CA

Two SSH secrets engines, each with its own ed25519 CA key generated inside
Vault:

| Mount | Role | Signs | TTL |
| --- | --- | --- | --- |
| `ssh-client-signer` | `me` | User certs for principal `me` only | 8h, max 24h |
| `ssh-host-signer` | `host` | Host certs for `k8s-1`..`k8s-4` and `192.168.1.40`..`43` | 1 year |

You log in with `userpass` or `cert`. Both give the `ssh-operator` policy,
which signs your user cert and signs host certs for the playbook.

Sign your key, then use plain `ssh` for the next 8 hours:

```
set -x VAULT_ADDR https://vault.cikli.com
vault login -method=cert -client-cert=$HOME/.vault-certs/me.crt \
  -client-key=$HOME/.vault-certs/me.key name=me
vault write -field=signed_key ssh-client-signer/sign/me \
  public_key=@$HOME/.ssh/id_ed25519.pub valid_principals=me \
  > ~/.ssh/id_ed25519-cert.pub
ssh me@192.168.1.40
```

`vault login -method=userpass username=me` works too.

The client cert in `~/.vault-certs/me.crt` expires on 2027-09-30. Renew it
with the `openssl x509 -req` command in "Client cert" below.

Vault terminates TLS itself, so its `cert` auth method can see client
certificates. That is why this app does not use a Terminate Gateway like the
others.

The `unsealer` sidecar checks Vault every 10 seconds. If Vault is initialized
and sealed, the sidecar unseals it with the key from the `vault-unseal-key`
Secret. If the TLS cert changes on disk, the sidecar sends SIGHUP to Vault so
it serves the renewed cert.

The unseal key is decrypted into a plain Secret in the `vault` namespace.
Anyone who can read that Secret, or who holds the sealed-secrets controller
key, can unseal Vault. The root token is never stored in the cluster.

Keep the existing `authorized_keys` on every node. They are the way in if Vault
or the cluster is down.

## Bootstrap

Run these steps once, from the repo root, in fish.

1. Add a local DNS record on the Pi-hole at 192.168.1.5:
   `vault.cikli.com` -> `192.168.1.97`. external-dns does not do this, because
   it only watches HTTPRoutes and this app uses a TLSRoute.

2. Wait for the pod. It shows `1/2` Ready, because Vault is sealed and not
   initialized, so its readiness probe fails.

   ```
   ssh me@192.168.1.40 kubectl get pods -n vault
   ```

3. Initialize Vault. The output goes to your Mac, not to the node.

   ```
   ssh me@192.168.1.40 kubectl exec -n vault vault-0 -c vault -- \
     env VAULT_TLS_SERVER_NAME=vault.cikli.com \
     vault operator init -key-shares=1 -key-threshold=1 -format=json \
     > ~/vault-init.json
   ```

   Save `unseal_keys_b64[0]` and `root_token` in your password manager. One
   share is enough, because the sidecar holds the whole key anyway.

4. Seal the unseal key.

   ```
   jq -j '.unseal_keys_b64[0]' ~/vault-init.json \
     | kubeseal --raw --cert apps/sealed-secrets/pub-cert.pem \
         --namespace vault --name vault-unseal-key --from-file=/dev/stdin
   ```

5. Write `apps/vault/templates/sealed-secret-unseal-key.yaml` with that output
   as the ciphertext. Do not add `creationTimestamp: null` (see commit
   3b43e0f).

   ```yaml
   apiVersion: bitnami.com/v1alpha1
   kind: SealedSecret
   metadata:
     name: vault-unseal-key
     namespace: vault
     annotations:
       # See apps/grafana/templates/sealed-secrets-influxdb-token.yaml.
       argocd.argoproj.io/sync-options: ServerSideApply=false
   spec:
     encryptedData:
       key: <CIPHERTEXT>
     template:
       metadata:
         name: vault-unseal-key
         namespace: vault
   ```

6. Commit and push. Within a minute of the sync, the sidecar unseals Vault.

   ```
   ssh me@192.168.1.40 kubectl logs -n vault vault-0 -c unsealer
   ```

7. Check it from your Mac.

   ```
   set -x VAULT_ADDR https://vault.cikli.com
   vault status
   ```

8. Delete `~/vault-init.json`. The key and token are in your password manager.

## Bootstrap the SSH CA

The config Job logs in with Kubernetes auth. Kubernetes auth cannot configure
itself, so set it up once with the root token. Do this before the Job first
runs, or the Job fails until you do.

1. Log in with the root token, from the repo root.

   ```
   set -x VAULT_ADDR https://vault.cikli.com
   vault login
   ```

2. Enable Kubernetes auth and bind the Job's ServiceAccount to its policy.
   Vault checks tokens with its own ServiceAccount, which the chart binds to
   `system:auth-delegator`.

   ```
   vault auth enable kubernetes
   vault write auth/kubernetes/config \
     kubernetes_host=https://kubernetes.default.svc:443
   vault policy write vault-config apps/vault/files/vault-config.hcl
   vault write auth/kubernetes/role/vault-config \
     bound_service_account_names=vault-config \
     bound_service_account_namespaces=vault \
     audience=vault token_policies=vault-config token_ttl=10m
   ```

3. Seal a password for the `me` userpass login.

   ```
   read -s -P 'Vault password for me: ' pw
   printf %s $pw | kubeseal --raw --cert apps/sealed-secrets/pub-cert.pem \
     --namespace vault --name vault-userpass --from-file=/dev/stdin
   set -e pw
   ```

4. Write `apps/vault/templates/sealed-secret-userpass.yaml` with that output.
   It uses the same layout as the unseal key, with name `vault-userpass` and
   data key `password`.

5. Commit and push. Check the Job log.

   ```
   ssh me@192.168.1.40 kubectl logs -n vault job/vault-config
   ```

6. Log in with your client cert, sign your key, and run the playbook. See
   "SSH CA" above for the login and signing commands.

   ```
   ansible-playbook -i apps/vault/ansible/inventory.yaml apps/vault/ansible/playbook.yaml
   ```

7. Check that a signed login works, and that the host cert is used.

   ```
   ssh -v me@192.168.1.40 true 2>&1 | grep -E "Server host certificate|Authenticated"
   ```

8. Revoke the root token. A new one can be made with
   `vault operator generate-root` and the unseal key.

   ```
   vault token revoke -self
   ```

## Client cert

The `cert` login trusts `files/client-ca.crt`. Its key and your client cert
are in `~/.vault-certs` on your Mac. They were made like this:

```
cd ~/.vault-certs
openssl req -x509 -newkey ed25519 -nodes -keyout client-ca.key \
  -out client-ca.crt -days 3650 -subj "/CN=cikli.com Vault client CA"
openssl req -newkey ed25519 -nodes -keyout me.key -out me.csr -subj "/CN=me"
printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' > me.ext
openssl x509 -req -in me.csr -CA client-ca.crt -CAkey client-ca.key \
  -CAcreateserial -out me.crt -days 365 -extfile me.ext
```

Use Homebrew's `openssl`. The macOS LibreSSL build may not handle ed25519.
If the CA changes, commit the new `client-ca.crt`, and the Job updates Vault.

## Host certs

The playbook signs each node's ed25519 host key for one year. Run it again
before then. It rewrites the certs every time.

The playbook also adds one `@cert-authority` line, tagged `vault-host-ca`,
to your `~/.ssh/known_hosts`. Old per-host entries still work and can stay.

## Upgrade

Bump `version`, `appVersion` and the dependency in `Chart.yaml`, and the
`unsealer` image tag in `values.yaml`, together. The sidecar should run the
same CLI version as the server.
