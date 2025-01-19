# SEALED SECRETS WAY
```
kubectl create secret generic mysecret --dry-run=client \
--from-file=ssh-privatekey=/Users/me/.ssh/id_ed25519_argocd \
--from-file=known_hosts=/dev/null -o json > argocd-ssh-key.json

kubeseal --name argocd-ssh-key -n argocd -f argocd-ssh-key.json \
-w argocd-ssh-key-encrypted.json --controller-name sealed-secrets \
--controller-namespace sealed-secrets

kubectl create -f argocd-ssh-key-encrypted.json
```

```
argocd app create --file applicationset.yaml \
--server argocd.cikli.com --insecure
```

# AUTH OLD WAY
Used this command to add the repo and provide the SSH key used to access Github
`argocd repo add 'git@github.com:D1g1talS0ul/kubernetes-apps.git' --name 'app-of-apps' --ssh-private-key-path ~/.ssh/id_ed25519_argocd --insecure-ignore-host-key --server argocd.cikli.com --insecure`

## OLD WAY
```
kubectl create secret generic argocd-ssh-key \
        --namespace argocd \
        --from-file=ssh-privatekey=/Users/me/.ssh/id_ed25519_argocd \
        --from-file=known_hosts=/dev/null
```

# HELM
Download
`helm fetch grafana/grafana --untar --untardir ./helm-charts/`