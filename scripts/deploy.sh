#!/usr/bin/env bash
# Applies the only kind-api resources that are NOT GitOps-managed:
#   - the namespace (needed before the Secret can be created)
#   - the Secret, kept out of what ArgoCD syncs so credentials have their
#     own path (swap for Sealed Secrets / External Secrets in a real setup)
#
# Everything else — Rollout, Service, Ingress, ConfigMap, RBAC, HPA, canary
# AnalysisTemplate — lives in gitops/apps/kind-api/ and is synced by the
# `kind-api` ArgoCD Application (gitops/argocd/app-of-apps.yaml).
set -euo pipefail
kubectl apply -f manifests/namespace.yaml
kubectl apply -f manifests/secret.yaml
