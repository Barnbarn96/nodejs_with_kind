#!/usr/bin/env bash
# Applies the only kind-api resources that are NOT GitOps-managed, in each
# environment's namespace:
#   - the namespace itself (needed before the Secret can be created)
#   - the Secret, kept out of what ArgoCD syncs so credentials have their
#     own path (swap for Sealed Secrets / External Secrets in a real setup)
#
# Everything else — Rollout, Service, Ingress, ConfigMap, RBAC, HPA, canary
# AnalysisTemplate — lives in gitops/apps/kind-api/ (base + dev/prod
# overlays) and is synced by the kind-api / kind-api-dev ArgoCD
# Applications (gitops/argocd/app-of-apps.yaml).
set -euo pipefail

# prod (kind-demo) and dev (kind-api-dev)
for ns in kind-demo kind-api-dev; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n "$ns" -f manifests/secret.yaml
done
