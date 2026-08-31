# kubernetes-apps

GitOps source for the `cikli.com` homelab cluster. Argo CD reads this repo and
syncs every app in `apps/`.

## Layout

| Path | Purpose |
| --- | --- |
| `appproject.yaml` | The `platform` AppProject. Bootstrap applies it by hand. |
| `applicationset.yaml` | The `appset` ApplicationSet. Bootstrap applies it by hand. |
| `apps/<name>/` | One app. The directory name becomes the Application name and the namespace. |
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

Cilium, CoreDNS and cert-manager are not in this repo. Install them first. The
`platform` AppProject denies writes to `kube-system` for this reason.

1. Install Cilium with Helm. Enable the Gateway API.

   ```
   helm upgrade --install cilium cilium/cilium --version 1.18.0 \
     --namespace kube-system -f cilium-values.yaml
   ```

2. Apply the AppProject. The apps cannot sync before the project exists.

   ```
   kubectl apply -f appproject.yaml
   ```

3. Apply the ApplicationSet.

   ```
   kubectl apply -f applicationset.yaml
   ```

4. Wait for `sealed-secrets` to report Healthy. Grafana needs the controller to
   unseal its admin password.

   ```
   kubectl get application sealed-secrets -n argocd -w
   ```

5. Watch the other apps converge.

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
the namespace before step 3.

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

- Alloy runs with the upstream default config. It discovers Kubernetes objects
  and forwards nothing. No app ships logs to Loki.
- `apps/argocd/argocd-ssh-key-encrypted.json` is unused. The generator reads this
  repo over HTTPS. The file stays for the day the repo needs SSH again.
- Chart dependencies are pinned by exact version, not by digest. No `Chart.lock`
  is committed, so a chart bump needs no second commit.
