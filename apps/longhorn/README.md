# INSTALL
How I had longhorn installed before ArgoCD
`helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace --set defaultSettings.defaultDataPath="/storage01"`