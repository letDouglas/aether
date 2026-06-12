#!/usr/bin/env bash
# Aether Platform - Management Cluster Bootstrap
# This script orchestrates the provisioning of the 'aether-mgmt' Kind cluster 
# and the initialization of Cluster API (CAPI) with the vcluster provider.

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

# Ensure the local environment matches the pinned version requirements
export PATH="$HOME/.local/bin:$PATH"
command -v mise &>/dev/null && eval "$(mise activate bash)"

# Verify mandatory binaries
for cmd in kind kubectl helm clusterctl envsubst; do
  command -v "$cmd" &>/dev/null || { echo -e "${RED}[ERROR] $cmd not found${NC}"; exit 1; }
done

# Detect and configure Docker socket for cross-platform support (Colima/OrbStack/Docker)
export DOCKER_SOCKET="/var/run/docker.sock"
[ -S "$HOME/.colima/default/docker.sock" ] && export DOCKER_SOCKET="$HOME/.colima/default/docker.sock"
[ -S "$HOME/.orbstack/run/docker.sock"   ] && export DOCKER_SOCKET="$HOME/.orbstack/run/docker.sock"
export DOCKER_HOST="unix://$DOCKER_SOCKET"

echo -e "${GREEN}[INFO] Docker socket: $DOCKER_SOCKET${NC}"
docker info &>/dev/null || { echo -e "${RED}[ERROR] Docker not reachable${NC}"; exit 1; }

# Provision the management cluster using declarative configuration
if kind get clusters 2>/dev/null | grep -q "^aether-mgmt$"; then
  echo -e "${YELLOW}[WARN] Cluster already exists, skipping${NC}"
else
  envsubst < bootstrap/kind-config.yaml | kind create cluster --config -
fi

# Await control-plane readiness before attempting to bootstrap CAPI
kubectl wait --for=condition=Ready node/aether-mgmt-control-plane --timeout=120s

# Initialize CAPI with topology features (ClusterClass) enabled
export CLUSTER_TOPOLOGY=true
clusterctl init --infrastructure vcluster

# Patch upstream images: The CAPI vcluster provider currently references deprecated
# GCR images. We patch these to community-supported alternatives to maintain stability.
echo -e "${YELLOW}[INFO] Applying upstream image patches for provider resiliency...${NC}"
kubectl patch deployment cluster-api-provider-vcluster-controller-manager \
  -n cluster-api-provider-vcluster-system \
  --type=json \
  -p '[
    {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"docker.io/loftsh/cluster-api-provider-vcluster:0.2.2"},
    {"op":"replace","path":"/spec/template/spec/containers/1/image","value":"quay.io/brancz/kube-rbac-proxy:v0.8.0"}
  ]' || true

echo -e "${GREEN}[SUCCESS] aether-mgmt ready${NC}"
[ -d "$HOME/.kube/clusters" ] && kind get kubeconfig --name aether-mgmt > "$HOME/.kube/clusters/aether-mgmt.yaml"