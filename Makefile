# Aether Makefile
# Platform Infrastructure Management

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Cluster configuration
MGMT_CLUSTER_NAME := aether-mgmt

# Pinned versions to keep local environments consistent across workstations
ARGOCD_VERSION := 7.7.0
ARGOCD_NAMESPACE := argocd

.PHONY: help bootstrap bootstrap-argocd vault-unseal clusters-up clusters-kubeconfig status down clean

help: ## Show this help message
	@echo "Aether Platform CLI"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Provision management cluster, deploy ArgoCD, and apply GitOps root
	@echo "--> Phase 1: Bootstrapping management cluster..."
	@chmod +x bootstrap/init.sh
	@./bootstrap/init.sh
	@echo "--> Phase 2: Deploying ArgoCD..."
	@$(MAKE) bootstrap-argocd
	@echo "--> Phase 3: Applying GitOps Root App..."
	@kubectl apply -f clusters/management/root.yaml
	@echo "--> ArgoCD will now reconcile Vault, VSO, and CAPI clusters from Git."
	@echo "--> Run 'make vault-unseal' once Vault pod is Running."

bootstrap-argocd: ## Deploy ArgoCD using Helm with local values
	@echo "--> Adding Argo Helm repository..."
	@helm repo add argo https://argoproj.github.io/argo-helm --force-update
	@echo "--> Installing ArgoCD chart version $(ARGOCD_VERSION)..."
	@helm upgrade --install argocd argo/argo-cd \
		--version $(ARGOCD_VERSION) \
		--namespace $(ARGOCD_NAMESPACE) \
		--create-namespace \
		-f clusters/management/argocd/values.yaml \
		--wait
	@echo "--> Waiting for ArgoCD API server readiness..."
	@kubectl wait --namespace $(ARGOCD_NAMESPACE) \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/name=argocd-server \
		--timeout=150s
	@echo "--> ArgoCD deployment successful."
	@echo "--> Initial admin password:"
	@kubectl -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

vault-unseal: ## Initialize and unseal Vault, then configure it via OpenTofu
	@mkdir -p build
	@IS_INIT=$$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null | jq -r '.initialized' || echo "false"); \
	if [ "$$IS_INIT" = "false" ]; then \
		echo "--> Vault is not initialized. Clearing stale keys from build/..."; \
		rm -f build/vault-init.json; \
	fi
	@if [ -s build/vault-init.json ] && grep -q root_token build/vault-init.json 2>/dev/null; then \
		echo "--> Found existing build/vault-init.json, reusing it."; \
	else \
		echo "--> Initializing Vault (1 key share)..."; \
		kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > build/vault-init.json.tmp; \
		if grep -q root_token build/vault-init.json.tmp; then \
			mv build/vault-init.json.tmp build/vault-init.json; \
		else \
			rm -f build/vault-init.json.tmp; \
			echo "ERROR: vault init failed."; \
			exit 1; \
		fi; \
	fi
	@UNSEAL_KEY=$$(jq -r '.unseal_keys_b64[0]' build/vault-init.json); \
	ROOT_TOKEN=$$(jq -r '.root_token' build/vault-init.json); \
	echo "--> Unsealing Vault..."; \
	kubectl exec -n vault vault-0 -- vault operator unseal $$UNSEAL_KEY; \
	echo "--> Starting port-forward to Vault..."; \
	kubectl port-forward -n vault svc/vault 8200:8200 & \
	PF_PID=$$!; \
	sleep 3; \
	echo "--> Running OpenTofu vault-global..."; \
	VAULT_TOKEN=$$ROOT_TOKEN tofu -chdir=terraform/vault-global init -input=false; \
	VAULT_TOKEN=$$ROOT_TOKEN tofu -chdir=terraform/vault-global apply -auto-approve; \
	kill $$PF_PID 2>/dev/null || true; \
	echo "✅ Vault unsealed and configured. ROOT TOKEN: $$ROOT_TOKEN"

clusters-up: ## Provision ml/serving vclusters via GitOps, then wire Vault trust for aether-ml
	@mkdir -p build/kubeconfigs
	@kind get kubeconfig --name aether-mgmt > build/kubeconfigs/management.yaml
	@echo "--> Waiting for CAPI to generate aether-ml kubeconfig..."
	@until kubectl get secret aether-ml-kubeconfig -n aether-ml >/dev/null 2>&1; do sleep 5; done
	@echo "--> Wiring Vault trust for aether-ml..."
	@ROOT_TOKEN=$$(jq -r '.root_token' build/vault-init.json); \
		kubectl port-forward -n vault svc/vault 8200:8200 >/dev/null 2>&1 & \
		PF_PID=$$!; \
		sleep 2; \
		VAULT_TOKEN=$$ROOT_TOKEN vcluster connect aether-ml -n aether-ml -- bash -c ' \
			kubectl config view --minify --flatten > $${PWD}/build/kubeconfigs/aether-ml.yaml && \
			tofu -chdir=$${PWD}/terraform/vault-ml init -input=false && \
			tofu -chdir=$${PWD}/terraform/vault-ml apply -auto-approve \
		'; \
		RESULT=$$?; \
		kill $$PF_PID 2>/dev/null; \
		exit $$RESULT
	@echo "✅ Clusters ready, Vault trust wired for aether-ml."
	
clusters-kubeconfig: ## Extract child cluster kubeconfigs
	@mkdir -p build/kubeconfigs
	@vcluster connect aether-ml -n aether-ml --update-config=false --kubeconfig=build/kubeconfigs/ml.yaml
	@vcluster connect aether-serving -n aether-serving --update-config=false --kubeconfig=build/kubeconfigs/serving.yaml
	@echo "--> Kubeconfigs extracted to build/kubeconfigs/"

status: ## Show health overview
	@echo "--> Checking management cluster health..."
	@kubectl cluster-info
	@echo "--> Checking CAPI components..."
	@kubectl get pods -A | grep -E "capi-|vcluster-system" || echo "No CAPI pods running yet."

down: ## Teardown the local environment and delete the kind cluster
	@echo "--> Destroying aether-mgmt kind cluster..."
	@kind delete cluster --name $(MGMT_CLUSTER_NAME) || echo "Cluster already deleted."

clean: ## Remove local temporary artifacts
	@echo "--> Cleaning workspace..."
	@rm -rf build/
	@echo "✅ Cleaned local artifacts."