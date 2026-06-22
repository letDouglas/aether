terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "vault" {
  address = "http://127.0.0.1:8200"
}

provider "kubernetes" {
  alias       = "management"
  config_path = "${path.module}/../../build/kubeconfigs/management.yaml"
}

provider "kubernetes" {
  alias       = "ml"
  config_path = "${path.module}/../../build/kubeconfigs/aether-ml.yaml"
}
