data "kubernetes_secret" "vc_aether_serving" {
  provider = kubernetes.management
  metadata {
    name      = "vc-aether-serving"
    namespace = "aether-serving"
  }
}

resource "kubernetes_service_account" "vault_reviewer" {
  provider = kubernetes.serving
  metadata {
    name      = "vault-reviewer"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_binding" "vault_reviewer" {
  provider = kubernetes.serving
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

resource "kubernetes_secret" "vault_reviewer_token" {
  provider = kubernetes.serving
  metadata {
    name      = "vault-reviewer-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.vault_reviewer.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
}

resource "vault_auth_backend" "kubernetes_serving" {
  type = "kubernetes"
  path = "aether-serving"
}

resource "vault_kubernetes_auth_backend_config" "serving" {
  backend                = vault_auth_backend.kubernetes_serving.path
  # Using short name to avoid the x509 SANs issue we found earlier
  kubernetes_host        = "https://aether-serving.aether-serving:443"
  kubernetes_ca_cert     = data.kubernetes_secret.vc_aether_serving.data["certificate-authority"]
  token_reviewer_jwt     = kubernetes_secret.vault_reviewer_token.data["token"]
  disable_iss_validation = true
}

resource "vault_kubernetes_auth_backend_role" "vso_serving" {
  backend                          = vault_auth_backend.kubernetes_serving.path
  role_name                        = "serving-cluster-role"
  
  # Aligned with our vso-client ServiceAccount decision
  bound_service_account_names      = ["vso-vault-secrets-operator-controller-manager", "vso-client"]
  bound_service_account_namespaces = ["vso", "ollama", "langfuse", "open-webui", "database"]
  
  token_policies                   = ["aether-policy"]
  token_ttl                        = 86400
}