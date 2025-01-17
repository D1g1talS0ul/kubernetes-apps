


# AUTH
Used this command to add the repo and provide the SSH key used to access Github
`argocd repo add 'git@github.com:D1g1talS0ul/kubernetes-apps.git' --name 'app-of-apps' --ssh-private-key-path ~/.ssh/id_ed25519_argocd --insecure-ignore-host-key --server argocd.cikli.com --insecure`

```
kubectl create secret generic argocd-ssh-key \
        --namespace argocd \
        --from-file=ssh-privatekey=/Users/me/.ssh/id_ed25519_argocd \
        --from-file=known_hosts=/dev/null
```

# GRAFANA
How I pulled in the Grafana Helm chart. Command was ran from the kubernetes-apps dir
`helm fetch grafana/grafana --untar --untardir ./grafana/helm-charts/`

# HELM
Download
`helm fetch grafana/grafana --untar --untardir ./helm-charts/`