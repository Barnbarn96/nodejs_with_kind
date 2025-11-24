#!/usr/bin/env bash
set -euo pipefail
kind create cluster --name inter --config kind-cluster.yaml
# Install ingress-nginx for kind
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
# Create namespace
kubectl apply -f manifests/namespace.yaml
# Install metrics-server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
