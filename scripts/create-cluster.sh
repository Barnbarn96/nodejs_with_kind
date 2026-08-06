#!/usr/bin/env bash
set -euo pipefail

# Idempotent re-run: `kind create cluster` errors out ("node(s) already
# exist") if the cluster is still registered, even if its containers are
# dead — and run-all.sh has no top-level `set -e`, so that failure used to
# cascade into build/load/deploy running against a nonexistent API server
# instead of stopping cleanly. Delete first so re-running run-all.sh always
# starts from a clean cluster.
if kind get clusters 2>/dev/null | grep -qx inter; then
  echo "Cluster 'inter' already exists — deleting it for a clean recreate..."
  kind delete cluster --name inter
fi

kind create cluster --name inter --config kind-cluster.yaml

# Pinned to a release tag, not `main` — the kind-provider manifest's
# nodeSelector/toleration for control-plane placement has changed upstream
# before, silently breaking the ingress <-> extraPortMappings assumption
# (kind-cluster.yaml only forwards hostPort 80/443 to the control-plane
# container, so the controller pod must land there, not on a worker).
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml

# Belt-and-suspenders: force control-plane placement regardless of what the
# manifest above currently contains, using the ingress-ready=true label this
# cluster's control-plane node carries (see kind-cluster.yaml's
# kubeadmConfigPatches). Only needs the Deployment object to exist, not for
# its pods to be ready yet.
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type='json' -p='[
  {"op":"add","path":"/spec/template/spec/nodeSelector","value":{"ingress-ready":"true"}},
  {"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}
]'

# Create namespace
kubectl apply -f manifests/namespace.yaml
# Install metrics-server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
