# INSTALL
https://github.com/bitnami-labs/sealed-secrets/tree/main/helm/sealed-secrets
https://rpi4cluster.com/k3s-sealed-secrets/

# USAGE
## CERTS
Public
`kubeseal --fetch-cert --controller-name sealed-secrets --controller-namespace sealed-secrets > sealed-secrets-master.pub`
Private
`kubectl get secret -A -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-master.key`
## SECRETS
Create
`echo -n bar | kubectl create secret generic mysecret --dry-run=client --from-file=foo=/dev/stdin -o json > sealed-secrets-test-secret.json`
Encrypt
`kubeseal -f sealed-secrets-test-secret.json -w sealed-secrets-test-secret-encrypted.json --controller-name sealed-secrets --controller-namespace sealed-secrets`
Add
`kubectl create -f sealed-secrets-test-secret-encrypted.json`
# UNINSTALL


# ERROR
