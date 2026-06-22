data "kubernetes_secret" "vc_aether_ml" {
  provider = kubernetes.management
  metadata {
    name      = "vc-aether-ml"
    namespace = "aether-ml"
  }
}

# ServiceAccount reviewer dentro il vcluster
resource "kubernetes_service_account" "vault_reviewer" {
  provider = kubernetes.ml
  metadata {
    name      = "vault-reviewer"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_binding" "vault_reviewer" {
  provider = kubernetes.ml
  metadata {
    name = "vault-reviewer"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.vault_reviewer.metadata[0].name
    namespace = "kube-system"
  }
}

# Token esplicito (necessario da Kubernetes 1.24+)
resource "kubernetes_secret" "vault_reviewer_token" {
  provider = kubernetes.ml
  metadata {
    name      = "vault-reviewer-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.vault_reviewer.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
}

# Auth backend dedicato al vcluster aether-ml
resource "vault_auth_backend" "kubernetes_ml" {
  type = "kubernetes"
  path = "aether-ml"
}

resource "vault_kubernetes_auth_backend_config" "ml" {
  backend                = vault_auth_backend.kubernetes_ml.path
  kubernetes_host        = "https://aether-ml.aether-ml:443"
  kubernetes_ca_cert     = data.kubernetes_secret.vc_aether_ml.data["certificate-authority"]
  token_reviewer_jwt     = kubernetes_secret.vault_reviewer_token.data["token"]
  disable_iss_validation = true
}

resource "vault_kubernetes_auth_backend_role" "vso_ml" {
  backend                          = vault_auth_backend.kubernetes_ml.path
  role_name                        = "ml-cluster-role"
  bound_service_account_names      = ["vso-vault-secrets-operator-controller-manager"]
  bound_service_account_namespaces = ["vso"]
  token_policies                   = ["aether-policy"]
  token_ttl                        = 86400
}

resource "vault_kubernetes_auth_backend_role" "garage_bootstrap" {
  backend                          = vault_auth_backend.kubernetes_ml.path
  role_name                        = "ml-garage-bootstrap-role"
  bound_service_account_names      = ["garage-bootstrap"]
  bound_service_account_namespaces = ["garage"]
  token_policies                   = ["aether-write-policy"]
  token_ttl                        = 3600
}
