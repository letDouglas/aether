#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

export PATH="$HOME/.local/bin:$PATH"
command -v mise &>/dev/null && eval "$(mise activate bash)"

for cmd in kind kubectl helm clusterctl envsubst; do
    command -v "$cmd" &>/dev/null || { echo -e "${RED}[ERROR] $cmd not found${NC}"; exit 1; }
done

# Detect Docker socket
export DOCKER_SOCKET="/var/run/docker.sock"
[ -S "$HOME/.colima/default/docker.sock" ] && export DOCKER_SOCKET="$HOME/.colima/default/docker.sock"
[ -S "$HOME/.orbstack/run/docker.sock"   ] && export DOCKER_SOCKET="$HOME/.orbstack/run/docker.sock"
export DOCKER_HOST="unix://$DOCKER_SOCKET"
echo -e "${GREEN}[INFO] Docker socket: $DOCKER_SOCKET${NC}"

docker info &>/dev/null || { echo -e "${RED}[ERROR] Docker not reachable${NC}"; exit 1; }

if kind get clusters 2>/dev/null | grep -q "^aether-mgmt$"; then
    echo -e "${YELLOW}[WARN] Cluster already exists, skipping${NC}"
else
    envsubst < bootstrap/kind-config.yaml | kind create cluster --config -
fi

kubectl wait --for=condition=Ready node/aether-mgmt-control-plane --timeout=120s

export CLUSTER_TOPOLOGY=true
clusterctl init --infrastructure docker

echo -e "${GREEN}[SUCCESS] aether-mgmt ready${NC}"

[ -d "$HOME/.kube/clusters" ] && kind get kubeconfig --name aether-mgmt > "$HOME/.kube/clusters/aether-mgmt.yaml"