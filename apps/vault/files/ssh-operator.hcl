# Policy for your logins (userpass and cert). It signs your user cert, and
# signs host certs so the Ansible playbook can renew them.

path "ssh-client-signer/sign/me" {
  capabilities = ["update"]
}
path "ssh-host-signer/sign/host" {
  capabilities = ["update"]
}
