#!/usr/bin/env bash
# Installs ArgoCD into an already-running kind cluster. This repo owns this
# step deliberately, rather than folding it into another project's cluster
# bring-up script — the KIND cluster is shared infrastructure, but "how to
# set up ArgoCD" belongs to whichever project actually needs ArgoCD.
#
# Prereq: a running kind cluster (`kind get clusters` should list one) —
# this script does not create one.
set -euo pipefail

echo "Creating argocd namespace..."
kubectl create namespace argocd 2>/dev/null || echo "  (already exists, skipping)"

echo "Installing ArgoCD..."
# --server-side: ArgoCD's CRDs (e.g. applicationsets.argoproj.io) are large
# enough that default client-side apply's last-applied-configuration
# annotation exceeds etcd's 256KiB annotation limit ("metadata.annotations:
# Too long"). Server-side apply tracks changes via managed fields instead,
# not that annotation, so it doesn't hit the limit.
# --force-conflicts: takes ownership of any fields left over from an
# earlier client-side-apply attempt (e.g. a failed run before this script
# switched to --server-side) — safe here since nothing else legitimately
# co-manages these objects.
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for argocd-server to be ready..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s

echo
echo "Done. To log in:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
echo "  kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "Then open https://localhost:8080 (user: admin)."
