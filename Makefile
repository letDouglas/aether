# Aether Makefile
# Platform Infrastructure Management

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Cluster configurations
MGMT_CLUSTER_NAME := aether-mgmt

# Tooling Versions (Pinned for 2026 stability)
ARGOCD_VERSION := 7.7.0
ARGOCD_NAMESPACE := argocd
VSO_NAMESPACE := vso
VSO_VERSION := 0.9.1
VAULT_VERSION := 0.29.1
VAULT_NAMESPACE := vault

.PHONY: help bootstrap bootstrap-argocd bootstrap-vso bootstrap-vault status down clean

help: ## Show this help message
	@echo "Aether Platform CLI"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

bootstrap: ## 1. Init kind mgmt cluster + CAPI + ArgoCD + VSO
	@echo "--> Phase 1: Bootstrapping Management Cluster..."
	@chmod +x bootstrap/init.sh
	@./bootstrap/init.sh
	@echo "--> Phase 2.1: Deploying ArgoCD..."
	@$(MAKE) bootstrap-argocd
	@echo "--> Phase 2.2: Deploying Vault..."
	@$(MAKE) bootstrap-vault
	@echo "--> Phase 2.3: Deploying VSO..."
	@$(MAKE) bootstrap-vso

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

bootstrap-vault: ## Deploy Vault via Helm
	@helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
	@kubectl delete mutatingwebhookconfiguration vault-agent-injector-cfg --ignore-not-found
	@helm upgrade --install vault hashicorp/vault \
      --version $(VAULT_VERSION) \
      --namespace $(VAULT_NAMESPACE) \
      --create-namespace \
      -f clusters/management/vault/values.yaml \
      --wait
	@echo "--> Waiting for Vault pod readiness..."
	@kubectl wait --namespace $(VAULT_NAMESPACE) \
        pod/vault-0 \
        --for=jsonpath='{.status.containerStatuses[0].started}'=true \
        --timeout=120s

bootstrap-vso: ## Deploy Vault Secrets Operator
	@helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
	@helm upgrade --install vso hashicorp/vault-secrets-operator \
		--version $(VSO_VERSION) \
		--namespace $(VSO_NAMESPACE) \
		--create-namespace \
		-f clusters/management/vso/values.yaml \
		--wait
	@echo "--> Applying VSO Connection and Auth config..."
	@kubectl apply -f clusters/management/vso/config.yaml
	
vault-unseal: ## Initialize and Unseal Vault, then configure it
	@mkdir -p build
	@# Check if Vault is actually initialized. If not, stale keys in build/ must be removed.
	@IS_INIT=$$(kubectl exec -n $(VAULT_NAMESPACE) vault-0 -- vault status -format=json 2>/dev/null | jq -r '.initialized' || echo "false"); \
	if [ "$$IS_INIT" = "false" ]; then \
		echo "--> Vault is not initialized. Clearing stale keys from build/..."; \
		rm -f build/vault-init.json; \
	fi
	@if [ -s build/vault-init.json ] && grep -q root_token build/vault-init.json 2>/dev/null; then \
		echo "--> Found existing build/vault-init.json, reusing it."; \
	else \
		echo "--> Initializing Vault (1 key share)..."; \
		kubectl exec -n $(VAULT_NAMESPACE) vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > build/vault-init.json.tmp; \
		if grep -q root_token build/vault-init.json.tmp; then \
			mv build/vault-init.json.tmp build/vault-init.json; \
		else \
			rm -f build/vault-init.json.tmp; \
			echo "ERROR: vault init failed (maybe already initialized with lost keys)."; \
			exit 1; \
		fi; \
	fi; \
	UNSEAL_KEY=$$(jq -r '.unseal_keys_b64[0]' build/vault-init.json); \
	ROOT_TOKEN=$$(jq -r '.root_token' build/vault-init.json); \
	if [ -z "$$UNSEAL_KEY" ] || [ "$$UNSEAL_KEY" = "null" ]; then \
		echo "ERROR: Failed to extract unseal key using jq."; \
		exit 1; \
	fi; \
	echo "--> Unsealing Vault..."; \
	kubectl exec -n $(VAULT_NAMESPACE) vault-0 -- vault operator unseal $$UNSEAL_KEY; \
	echo "--> Creating K8s Secret for Bootstrap Job Auth..."; \
	kubectl create secret generic vault-root-token -n $(VAULT_NAMESPACE) --from-literal=token=$$ROOT_TOKEN --dry-run=client -o yaml | kubectl apply -f -; \
	echo "--> Running Vault bootstrap job (Configuring K8s Auth)..."; \
	kubectl delete job vault-bootstrap -n $(VAULT_NAMESPACE) --ignore-not-found 2>/dev/null || true; \
	kubectl apply -f clusters/management/vault/vault-bootstrap-job.yaml; \
	kubectl wait --namespace $(VAULT_NAMESPACE) \
	    --for=condition=complete job/vault-bootstrap \
	    --timeout=120s; \
	echo "✅ Vault Unsealed and Configured. ROOT TOKEN: $$ROOT_TOKEN"

status: ## Show health overview
	@echo "--> Checking management cluster health..."
	@kubectl cluster-info
	@echo "--> Checking CAPI components..."
	# Changed grep pattern to look for vcluster provider pods
	@kubectl get pods -A | grep -E "capi-|vcluster-system" || echo "No CAPI pods running yet."

down: ## Teardown the local environment and delete kind cluster
	@echo "--> Destroying aether-mgmt kind cluster..."
	@kind delete cluster --name $(MGMT_CLUSTER_NAME) || echo "Cluster already deleted."

clean: ## Remove local temporary artifacts
	@echo "--> Cleaning workspace..."
	@rm -rf build/