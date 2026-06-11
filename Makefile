# Aether Makefile
# Platform Infrastructure Management

# Configuration
SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help bootstrap clusters-up deploy-all mcp-up demo status down clean

help: ## Show this help message
	@echo "Aether Platform CLI"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

bootstrap: ## 1. Init kind mgmt cluster + CAPI + ArgoCD + Vault
	@echo "--> Bootstrapping Management Cluster..."
	# Implementation logic will go here

clusters-up: ## 2. CAPI provisions ml + serving vclusters
	@echo "--> Provisioning CAPI clusters..."
	# Implementation logic will go here

deploy-all: ## 3. Sync all apps via ArgoCD
	@echo "--> Syncing GitOps state..."
	# Implementation logic will go here

mcp-up: ## 4. Build and deploy MCP server
	@echo "--> Deploying MCP Server..."
	# Implementation logic will go here

demo: ## 5. Run end-to-end pipeline + inference
	@echo "--> Running Demo Pipeline..."
	# Implementation logic will go here

status: ## 6. Show health overview of all clusters/apps
	@echo "--> Checking system health..."
	# Implementation logic will go here

down: ## 7. Teardown everything
	@echo "--> Destroying platform..."
	# Implementation logic will go here

clean: ## 8. Clean local build artifacts
	@echo "--> Cleaning workspace..."
	# Implementation logic will go here