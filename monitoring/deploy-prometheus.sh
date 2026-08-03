#!/usr/bin/env bash
# Deploy the Prometheus/Alertmanager stack, injecting the Discord webhook at
# deploy time instead of committing it.
#
#   export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/ID/TOKEN'
#   ./monitoring/deploy-prometheus.sh
#
# prometheus-values.yaml holds DISCORD_WEBHOOK_URL_PLACEHOLDER so the secret
# never lands in git. Running `helm upgrade -f prometheus-values.yaml` WITHOUT
# this script would push that literal placeholder into Alertmanager and silently
# break every Discord receiver.
#
# Helm merges lists by replacement, not by index, so a second -f overlay file
# can't patch a single receiver's URL — hence --set-string per receiver.
set -euo pipefail

if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
  echo "DISCORD_WEBHOOK_URL is not set." >&2
  echo "  export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/<id>/<token>'" >&2
  exit 1
fi

RELEASE="${RELEASE:-prom}"
NAMESPACE="${NAMESPACE:-monitoring}"
VALUES="$(dirname "$0")/prometheus-values.yaml"

# Indices match the `receivers:` order in prometheus-values.yaml:
#   0 discord-default, 1 discord-warnings, 2 discord-critical
#   3 triage-bridge  <- posts to Discord itself via the agent's .env, no URL here
helm upgrade --install "$RELEASE" prometheus-community/prometheus \
  --namespace "$NAMESPACE" \
  -f "$VALUES" \
  --set-string "alertmanager.config.receivers[0].discord_configs[0].webhook_url=$DISCORD_WEBHOOK_URL" \
  --set-string "alertmanager.config.receivers[1].discord_configs[0].webhook_url=$DISCORD_WEBHOOK_URL" \
  --set-string "alertmanager.config.receivers[2].discord_configs[0].webhook_url=$DISCORD_WEBHOOK_URL"

echo
echo "Deployed. Verify the placeholder was substituted:"
echo "  kubectl get cm ${RELEASE}-alertmanager -n ${NAMESPACE} -o yaml | grep -c PLACEHOLDER   # expect 0"
