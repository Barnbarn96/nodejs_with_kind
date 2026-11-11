#!/usr/bin/env bash
# Installs the Argo Rollouts controller into an already-running kind cluster.
# Same reasoning as install-argocd.sh: this repo owns its own dependencies
# rather than folding them into another project's cluster bring-up script.
set -euo pipefail

echo "Creating argo-rollouts namespace..."
kubectl create namespace argo-rollouts 2>/dev/null || echo "  (already exists, skipping)"

echo "Installing Argo Rollouts..."
# --server-side: same reasoning as install-argocd.sh — the Rollout CRD's
# schema is large enough to risk the same annotation-size issue.
# Pinned so respins are reproducible; override to upgrade deliberately.
ARGO_ROLLOUTS_VERSION="${ARGO_ROLLOUTS_VERSION:-v1.10.2}"
kubectl apply -n argo-rollouts --server-side --force-conflicts \
  -f "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/install.yaml"

echo "Waiting for the rollout controller to be ready..."
kubectl -n argo-rollouts rollout status deployment/argo-rollouts --timeout=180s

echo
echo "Done. Useful commands (no plugin required, works with plain kubectl):"
echo "  kubectl get rollout api -n kind-demo -o wide        # prod"
echo "  kubectl get rollout api -n kind-api-dev -o wide     # dev"
echo "  kubectl describe rollout api -n kind-demo"
echo
echo "Optional but much nicer output — install the kubectl-argo-rollouts plugin:"
echo "  https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation"
echo "  then: kubectl argo rollouts get rollout api -n kind-demo --watch"
