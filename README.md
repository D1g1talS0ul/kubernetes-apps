# kubernetes-apps

GitOps source for the `cikli.com` homelab cluster. Argo CD reads this repo and
syncs every app in `apps/`.

## Layout

| Path | Purpose |
| --- | --- |
| `appproject.yaml` | The `platform` AppProject. Bootstrap applies it by hand. |
| `applicationset.yaml` | The `appset` ApplicationSet. Bootstrap applies it by hand. |
| `apps/<name>/` | One app. The directory name becomes the Application name and the namespace. |
| `apps/gateway-api/` | Gateway API CRDs. The version must match the Cilium version. |
| `apps/components/` | Shared kustomize components. The generator excludes this path. |

Each app in `apps/` is either an umbrella Helm chart (`Chart.yaml` plus
`values.yaml`) or a kustomization (`kustomization.yaml`). Argo CD picks the tool
from the files it finds. Local `templates/` files hold the Cilium `Gateway` and
`HTTPRoute` for each app.

To add an app, create `apps/<name>/` and commit it. The generator finds it. Do
not edit `applicationset.yaml`.

## Check the context first

This repo is not the only cluster in your kubeconfig. The `prod` context is the
work cluster.

1. Print the current context.

   ```
   kubectl config current-context
   ```

2. If the context is not the homelab cluster, change it before you continue.

## Bootstrap from zero

Cilium, CoreDNS and cert-manager are not in this repo. Install them first. Helm
and Ansible manage Cilium and CoreDNS by hand, and nothing here renders them.

1. Apply the Gateway API CRDs by hand. Argo CD owns their version in
   `apps/gateway-api/`, but it is not running yet, and Cilium needs the CRDs at
   startup. Argo CD adopts them later.

   ```
   kubectl apply --server-side -k apps/gateway-api
   ```

2. Install Cilium with Helm. See "Upgrade Cilium" below for the version pair.

   ```
   helm upgrade --install cilium cilium/cilium --version <VERSION> \
     --namespace kube-system -f cilium-values.yaml
   ```

3. Apply the AppProject. The apps cannot sync before the project exists.

   ```
   kubectl apply -f appproject.yaml
   ```

4. Apply the ApplicationSet.

   ```
   kubectl apply -f applicationset.yaml
   ```

5. Wait for `sealed-secrets` to report Healthy. Grafana needs the controller to
   unseal its admin password.

   ```
   kubectl get application sealed-secrets -n argocd -w
   ```

6. Watch the other apps converge.

   ```
   kubectl get applications -n argocd
   ```

The apps sync in parallel, so some go red first. `sealed-secrets` must precede
Grafana, the prometheus-operator CRDs must precede the Longhorn ServiceMonitor,
and the Longhorn StorageClass must precede the Prometheus PVC. The retry backoff
in `applicationset.yaml` clears these races within a few minutes.

### Longhorn needs a privileged namespace

`CreateNamespace=true` makes a plain namespace with no labels. If the cluster
enforces Pod Security Admission at `restricted`, Longhorn fails to start. Label
the namespace before step 4.

```
kubectl create namespace longhorn-system
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged
```

## Upgrade a chart

1. Edit `version` and `appVersion` in `apps/<name>/Chart.yaml`.
2. Edit the matching `dependencies` version in the same file.
3. Render the chart to confirm the values still fit the new schema.

   ```
   helm dependency build apps/<name>
   helm template <name> apps/<name>
   ```

4. Commit and push. Argo CD syncs the change.

Upgrade Longhorn one minor version at a time. Longhorn does not support version
skips. See the three staged commits from the 1.9.1 to 1.12.1 upgrade.

## Upgrade Cilium

Read this section before you touch Cilium. On 2026-09-01 a Cilium bump took every
app offline for nine hours, and the cause was this step being missing.

Helm manages Cilium in `kube-system`. Cilium itself is not in this repo. The
Gateway API CRDs are, in `apps/gateway-api/`, and their version is tied to the
Cilium version.

| Cilium | Gateway API CRDs |
| --- | --- |
| 1.18.x | v1.2.0 |
| 1.20.1 | v1.6.1 |

To find the pair for any other release, read
`https://docs.cilium.io/en/v<VERSION>/network/servicemesh/gateway-api/gateway-api/`
and search for "Cilium supports Gateway API".

### Procedure

1. Look up the Gateway API version that the target Cilium release requires.
2. Bump the seven URLs in `apps/gateway-api/kustomization.yaml` to that version.
   Commit and push. Argo CD applies the CRDs. Do this before step 4, because
   Cilium reads the CRDs at startup.
3. Confirm Argo CD applied them.

   ```
   kubectl get application gateway-api -n argocd
   kubectl get crd gateways.gateway.networking.k8s.io \
     -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'
   ```

4. Save the current Helm values.

   ```
   helm get values cilium --namespace kube-system -o yaml > cilium-old-values.yaml
   ```

5. Upgrade Cilium.

   ```
   helm upgrade cilium cilium/cilium --version <VERSION> \
     --namespace kube-system -f cilium-old-values.yaml
   ```

6. Restart the operator. It checks the Gateway API CRDs only at startup, so it
   never recovers on its own after a CRD change.

   ```
   kubectl rollout restart deploy/cilium-operator -n kube-system
   ```

7. Verify. See the next section.

### Verify Gateway API after a Cilium change

Do not trust `kubectl get gateways`. A Gateway reports `PROGRAMMED=True` from its
last successful reconcile. If the controller is dead, that status is stale and
every Gateway still looks healthy while no app serves traffic.

Check these three things instead.

1. Confirm the operator found the CRDs. Any output here is a failure.

   ```
   kubectl logs -n kube-system -l io.cilium/app=operator --tail=400 \
     | grep "Required GatewayAPI resources are not found"
   ```

2. Confirm the Gateway API secret sync is registered. The line must name a
   Gateway API type. If it lists only `CiliumNetworkPolicy` and
   `CiliumClusterwideNetworkPolicy`, the Gateway API controller never started.

   ```
   kubectl logs -n kube-system -l io.cilium/app=operator --tail=400 \
     | grep "Setting up Secret synchronization"
   ```

3. Confirm one synced TLS secret exists per Gateway. An empty namespace means
   Envoy has no certificate and resets every TLS handshake.

   ```
   kubectl get secrets -n cilium-secrets
   ```

### Test a Gateway from the command line

Use `--resolve`. A Gateway listener matches on SNI, and connecting to the IP with
a `Host:` header sends no SNI, so the request fails even when the Gateway is
healthy.

```
curl -sk -o /dev/null -w "%{http_code}\n" \
  --resolve argocd.cikli.com:443:192.168.1.93 https://argocd.cikli.com
```

Wrong, and it always fails:

```
curl -k -H "Host: argocd.cikli.com" https://192.168.1.93
```

## Upgrade Argo CD

1. Edit the `install.yaml` version in `apps/argocd/kustomization.yaml`.
2. Render the output and confirm it is complete.

   ```
   kustomize build apps/argocd | rg -c '^kind:'
   ```

3. Confirm the ServiceMonitor selectors still match the Service labels.

   ```
   kustomize build apps/argocd | rg -B6 '^kind: Service$'
   ```

4. Commit and push.

Argo CD manages its own install. The three `argoproj.io` CRDs carry
`Prune=false`, so a bad render cannot delete every Application object.

## Sealed secrets

The controller runs in the `sealed-secrets` namespace. `apps/sealed-secrets/pub-cert.pem`
holds the public certificate.

1. Write the plain secret to a temporary file.

   ```
   kubectl create secret generic grafana-admin-secret --dry-run=client \
     --from-literal=admin-user=admin --from-literal=admin-password=CHANGEME \
     -n grafana -o json > /tmp/secret.json
   ```

2. Seal it into the app's `templates/` directory.

   ```
   kubeseal -f /tmp/secret.json -o yaml \
     --controller-name sealed-secrets --controller-namespace sealed-secrets \
     > apps/grafana/templates/sealed-secrets-admin-password-encrypted.yaml
   ```

3. Delete the temporary file.
4. Commit the sealed file. Never commit the plain file.

## Troubleshooting

### An app will not sync or refresh

Remove the finalizer.

```
kubectl patch application/<name> -n argocd --type json \
  --patch='[{"op": "remove", "path": "/metadata/finalizers"}]'
```

### Prometheus shows no data for an app

Prometheus selects all ServiceMonitors. See
`serviceMonitorSelectorNilUsesHelmValues` in `apps/prometheus/values.yaml`. If a
target is missing, the ServiceMonitor selector does not match the Service label.
Compare the two.

### Deleting the ApplicationSet

`preserveResourcesOnDeletion: true` keeps the workloads. Deleting the
ApplicationSet removes the Application objects only. Longhorn volumes and PVCs
survive.

## Known gaps

- external-dns runs with `--policy=upsert-only` and `--registry=noop`. It creates
  and updates DNS records and never deletes one, and it keeps no ownership record.
  After you remove an app or rename a host, delete the old record in Cloudflare by
  hand. The `echo.cikli.com` record is orphaned this way, because the echo test
  app was removed on 2026-09-01.
- Cilium runs with CiliumEndpointSlice off, which is the default, so the
  `ciliumendpointslices.cilium.io` CRD does not exist. The operator logs
  "CiliumEndpointSlice CRD cannot be found, skipping garbage collection" at info
  level. That message is correct and needs no action. The feature only reduces
  API server load on large clusters.
- `apps/argocd/argocd-ssh-key-encrypted.json` is unused. The generator reads this
  repo over HTTPS. The file stays for the day the repo needs SSH again.
- Chart dependencies are pinned by exact version, not by digest. No `Chart.lock`
  is committed, so a chart bump needs no second commit.
