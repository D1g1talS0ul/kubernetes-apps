# SEALED SECRETS WAY
Update values.yaml to define existingSecret: pointing to grafana-admin-secret created below

I manually merged the password into sealed-secrets-admin-password.json

```
echo -n blahblah | kubectl create secret generic grafana-admin-secret -n grafana --dry-run=client --from-file=admin-user=/dev/stdin \
-o json | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets > sealed-secrets-admin-password.json

echo -n blahblah | kubectl create secret generic grafana-admin-secret -n grafana --dry-run=client \
--from-file=admin-password=/dev/stdin -o json | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets 
```

