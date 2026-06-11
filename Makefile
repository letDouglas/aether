# Aether Makefile
# Platform Infrastructure Management

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Cluster configurations
MGMT_CLUSTER_NAME := aether-mgmt

# Tooling Versions (Pinned for 2026 stability)
ARGOCD_VERSION := 7.7.0
ARGOCD_NAMESPACE := argocd

.PHONY: help bootstrap bootstrap-argocd status down clean

help: ## Show this help message
	@echo "Aether Platform CLI"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

bootstrap: ## 1. Init kind mgmt cluster + CAPI + ArgoCD
	@echo "--> Phase 1: Bootstrapping Management Cluster..."
	@chmod +x bootstrap/init.sh
	@./bootstrap/init.sh
	@echo "--> Phase 2.1: Deploying ArgoCD..."
	@$(MAKE) bootstrap-argocd

bootstrap-argocd: ## Deploy ArgoCD using Helm via local values
	@echo "--> Adding ArgoProj Helm repository..."
	@helm repo add argo https://argoproj.github.io/argo-helm --force-update
	@echo "--> Installing ArgoCD Chart version $(ARGOCD_VERSION)..."
	@helm upgrade --install argocd argo/argo-cd \
		--version $(ARGOCD_VERSION) \
		--namespace $(ARGOCD_NAMESPACE) \
		--create-namespace \
		-f clusters/management/argocd/values.yaml \
		--wait
	@echo "--> Waiting for ArgoCD API Server readiness..."
	@kubectl wait --namespace $(ARGOCD_NAMESPACE) \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/name=argocd-server \
		--timeout=150s
	@echo "--> ArgoCD Deployment Successful."
	@echo "--> Initial Admin Password:"
	@kubectl -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

status: ## Show health overview of infrastructure and applications
	@echo "--> [Cluster Status]"
	@kubectl cluster-info
	@echo -e "\n--> [CAPI Components]"
	@kubectl get pods -A | grep -E "capi-|capd-" || echo "No CAPI pods running."
	@echo -e "\n--> [ArgoCD Status]"
	@kubectl get pods -n $(ARGOCD_NAMESPACE) || echo "ArgoCD namespace not found."

down: ## Teardown the local environment and delete kind cluster
	@echo "--> Destroying aether-mgmt kind cluster..."
	@kind delete cluster --name $(MGMT_CLUSTER_NAME) || echo "Cluster already deleted."

clean: ## Remove local temporary artifacts
	@echo "--> Cleaning workspace..."
	@rm -rf build/