#!/usr/bin/env bash
set -euo pipefail

# Chart versions are pinned so a respin months from now installs what was
# tested. Override with env vars to upgrade deliberately.
KUBE_PROM_STACK_VERSION="${KUBE_PROM_STACK_VERSION:-93.2.0}"
GRAFANA_CHART_VERSION="${GRAFANA_CHART_VERSION:-10.5.15}"

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

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
#
# alertmanagerConfigMatcherStrategy=None — required by
# monitoring/alertmanager-config.yaml (see the note in
# monitoring/deploy-operator-resources.sh). Set here rather than with
# `kubectl patch` so Helm owns the field and an upgrade can't revert it.
helm upgrade --install kube-prom-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version "$KUBE_PROM_STACK_VERSION" \
  --set alertmanager.alertmanagerSpec.alertmanagerConfigMatcherStrategy.type=None \
  --set grafana.enabled=false \
  --set kubeControllerManager.enabled=false \
  --set kubeScheduler.enabled=false \
  --set kubeProxy.enabled=false

helm upgrade --install grafana grafana/grafana -n monitoring \
  --version "$GRAFANA_CHART_VERSION" \
  -f monitoring/grafana-values.yaml

# The operator needs to reconcile and register its Alertmanager CR before our
# AlertmanagerConfig/PrometheusRule/ServiceMonitor can apply cleanly against it.
echo "Waiting for the Alertmanager custom resource to be created by the operator..."
until kubectl get alertmanager kube-prom-stack-kube-prome-alertmanager -n monitoring >/dev/null 2>&1; do
  sleep 3
done

./monitoring/deploy-operator-resources.sh
