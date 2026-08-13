#!/usr/bin/env bash
# The app's own workload resource (formerly manifests/deployment.yaml) is
# deliberately NOT applied here — it's now a Rollout managed by ArgoCD
# (gitops/apps/kind-api/), built via .github/workflows/build-and-push.yml.
# Applying a plain Deployment with the same pod selector here would fight
# ArgoCD for ownership of the same pods. Everything else the app needs
# (RBAC, config, storage, networking) still gets applied imperatively.
set -euo pipefail
kubectl apply -f manifests/configmap.yaml
kubectl apply -f manifests/hpa.yaml
kubectl apply -f manifests/ingress.yaml
kubectl apply -f manifests/namespace.yaml
kubectl apply -f manifests/pv.yaml
kubectl apply -f manifests/pvc.yaml
kubectl apply -f manifests/rbac.yaml
kubectl apply -f manifests/secret.yaml
kubectl apply -f manifests/service.yaml