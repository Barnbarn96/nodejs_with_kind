#!/usr/bin/env bash
set -euo pipefail

kubectl create namespace monitoring || true

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# kube-prometheus-stack (Operator-based: PrometheusRule/ServiceMonitor/
# AlertmanagerConfig CRDs) replaces the old prometheus-community/prometheus
# Helm-values approach — see monitoring/MIGRATION.md for why and what changed.
#
# grafana disabled here — the separate standalone `grafana` release below is
# what's actually used, so the chart's bundled one would just be a second,
# unused Grafana instance.
#
# kubeControllerManager/kubeScheduler/kubeProxy disabled — kind's kubeadm
# binds these components' metrics to 127.0.0.1 only, so Prometheus can never
# scrape them on a kind cluster. Leaving them enabled produces permanently
# firing "*InstanceUnreachable" alerts for something kind fundamentally
# can't expose, not a real signal.
helm upgrade --install kube-prom-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.enabled=false \
  --set kubeControllerManager.enabled=false \
  --set kubeScheduler.enabled=false \
  --set kubeProxy.enabled=false

helm upgrade --install grafana grafana/grafana -n monitoring -f monitoring/grafana-values.yaml

# The operator needs to reconcile and register its Alertmanager CR before our
# AlertmanagerConfig/PrometheusRule/ServiceMonitor can apply cleanly against it.
echo "Waiting for the Alertmanager custom resource to be created by the operator..."
until kubectl get alertmanager kube-prom-stack-kube-prome-alertmanager -n monitoring >/dev/null 2>&1; do
  sleep 3
done

./monitoring/deploy-operator-resources.sh
