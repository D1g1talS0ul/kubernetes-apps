# INSTALL
How I had longhorn installed before ArgoCD
`helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace --set defaultSettings.defaultDataPath="/storage01"`

# UNINSTALL
Remove stuck CRDs
```bash
kubectl delete ValidatingWebhookConfiguration longhorn-webhook-validator
kubectl delete MutatingWebhookConfiguration longhorn-webhook-mutator

for crd in $(kubectl get crd -o jsonpath={.items[*].metadata.name} | tr ' ' '\n' | grep longhorn.io); do
  kubectl -n longhorn-system get $crd -o yaml | sed "s/\- longhorn.io//g" | kubectl apply -f -
  kubectl -n longhorn-system delete $crd --all
  kubectl delete crd/$crd
done
```

# ERROR
Saw this in ArgoCD `waiting for completion of hook batch/Job/longhorn-pre-upgrade`

`k describe jobs longhorn-pre-upgrade -n longhorn-system`
> Warning  FailedCreate  50s (x13 over 7m53s)  job-controller  Error creating: pods "longhorn-pre-upgrade-" is forbidden: error looking up service account longhorn-system/longhorn-service-account: serviceaccount "longhorn-service-account" not found

Fix was to manually sync `longhorn-service-account` in ArgoCD 