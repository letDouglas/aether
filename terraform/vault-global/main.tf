resource "vault_mount" "kv" {
  path = "secret"
  type = "kv-v2"
}

resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  path = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "management" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = "https://kubernetes.default.svc"
}

resource "vault_policy" "aether_read" {
  name   = "aether-policy"
  policy = <<-EOT
    path "secret/data/aether/*" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "aether_write" {
  name   = "aether-write-policy"
  policy = <<-EOT
    path "secret/data/aether/garage" {
      capabilities = ["create", "update", "patch", "read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "vso" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "vso-role"
  bound_service_account_names      = ["vso-vault-secrets-operator-controller-manager"]
  bound_service_account_namespaces = ["*"]
  token_policies                   = [vault_policy.aether_read.name]
  token_ttl                        = 86400
}