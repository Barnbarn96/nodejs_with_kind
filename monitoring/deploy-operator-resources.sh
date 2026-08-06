#!/usr/bin/env bash
# Applies the Prometheus Operator CRDs (ServiceMonitor, PrometheusRule,
# AlertmanagerConfig) that replace prometheus-values.yaml's Helm-values
# approach. Requires the kube-prom-stack release to already be installed
# (see monitoring/MIGRATION.md step 1) — this script only applies the
# resources the operator watches, it doesn't install the operator itself.
#
#   export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/<id>/<token>'
#   ./monitoring/deploy-operator-resources.sh
set -euo pipefail

if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
  echo "DISCORD_WEBHOOK_URL is not set." >&2
  echo "  export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/<id>/<token>'" >&2
  exit 1
fi

NAMESPACE="${NAMESPACE:-monitoring}"
DIR="$(dirname "$0")"

# Never committed — created directly in the cluster from the env var, same
# reasoning as the --set-string substitution in deploy-prometheus.sh.
kubectl create secret generic discord-webhooks \
  --namespace "$NAMESPACE" \
  --from-literal=default-url="$DISCORD_WEBHOOK_URL" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$DIR/servicemonitor.yaml"
kubectl apply -f "$DIR/rules/api-alerts.yaml"
kubectl apply -f "$DIR/rules/pod-health.yaml"
kubectl apply -f "$DIR/alertmanager-config.yaml"

# By default the Operator injects a `namespace=<AlertmanagerConfig's own
# namespace>` matcher into every route and inhibit rule it generates, to
# stop one namespace's config from affecting another's alerts. Since this
# AlertmanagerConfig lives in `monitoring` but the alerts it's meant to
# route come from `default` (where the demo pods run), that scoping would
# silently make every rule above unreachable — confirmed live: triage-bridge
# never received an alert until this was disabled. See MIGRATION.md.
kubectl patch alertmanager kube-prom-stack-kube-prome-alertmanager -n "$NAMESPACE" \
  --type='merge' -p='{"spec":{"alertmanagerConfigMatcherStrategy":{"type":"None"}}}'

echo
echo "Applied. Verify with:"
echo "  kubectl get prometheusrule,servicemonitor,alertmanagerconfig -n $NAMESPACE"
