# Policy for the config Job (files/configure.sh). The Job rewrites this policy
# on every run, so edit it here and let Argo CD sync it.
#
# It can manage mounts, auth methods and ACL policies, so treat the vault-config
# ServiceAccount as an administrator. It cannot touch the Kubernetes auth role
# that grants this policy, so it cannot hand the policy to anything else.

path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/mounts/ssh-client-signer" {
  capabilities = ["create", "read", "update", "sudo"]
}
path "sys/mounts/ssh-host-signer" {
  capabilities = ["create", "read", "update", "sudo"]
}
path "sys/mounts/ssh-host-signer/tune" {
  capabilities = ["read", "update", "sudo"]
}

path "sys/auth" {
  capabilities = ["read"]
}
path "sys/auth/userpass" {
  capabilities = ["create", "read", "update", "sudo"]
}
path "sys/auth/cert" {
  capabilities = ["create", "read", "update", "sudo"]
}

path "sys/policies/acl/vault-config" {
  capabilities = ["create", "read", "update"]
}
path "sys/policies/acl/ssh-operator" {
  capabilities = ["create", "read", "update"]
}

path "ssh-client-signer/config/ca" {
  capabilities = ["create", "read", "update"]
}
path "ssh-client-signer/roles/*" {
  capabilities = ["create", "read", "update"]
}
path "ssh-host-signer/config/ca" {
  capabilities = ["create", "read", "update"]
}
path "ssh-host-signer/roles/*" {
  capabilities = ["create", "read", "update"]
}

path "auth/userpass/users/me" {
  capabilities = ["create", "read", "update"]
}
path "auth/cert/certs/me" {
  capabilities = ["create", "read", "update"]
}
