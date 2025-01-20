# SEALED SECRETS WAY
Update values.yaml to define existingSecret: pointing to grafana-admin-secret created below

```
kubectl create secret generic grafana-admin-secret --dry-run=client \
      --from-literal=admin-user=blahblah --from-literal=admin-password=blahblah \
      -n grafana -o yaml > sealed-secrets-admin-password.yaml

kubeseal -f sealed-secrets-admin-password.yaml -w sealed-secrets-admin-password-encrypted.yaml \
      --controller-name sealed-secrets --controller-namespace sealed-secrets 
```

