# SEALED SECRETS WAY
Update values.yaml to define existingSecret: pointing to grafana-admin-secret created below

```
kubectl create secret generic grafana-admin-secret --dry-run=client \
--from-literal=admin-user=blahblah --from-literal=admin-password=blahblah \
-n grafana -o json > sealed-secrets-admin-password.json

kubeseal -f sealed-secrets-admin-password.json -w sealed-secrets-admin-password.json \
--controller-name sealed-secrets --controller-namespace sealed-secrets
```

