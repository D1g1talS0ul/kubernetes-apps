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

Keep the root token until the SSH CA configuration is in place. That step
enables Kubernetes auth with it. Revoke it afterwards with
`vault token revoke -self`. A new one can be made with
`vault operator generate-root` and the unseal key.

## Upgrade

Bump `version`, `appVersion` and the dependency in `Chart.yaml`, and the
`unsealer` image tag in `values.yaml`, together. The sidecar should run the
same CLI version as the server.
