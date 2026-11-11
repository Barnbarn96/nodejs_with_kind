#!/bin/bash
# Stop on the first failing step instead of cascading — without this, an
# early failure (e.g. create-cluster.sh) used to leave later steps running
# build/load/deploy against a half-broken or nonexistent cluster, producing
# confusing downstream errors instead of a clean stop.
set -euo pipefail

# Checked up front, not at the last step: deploy-monitoring.sh needs this to
# substitute the webhook placeholder, and failing there means a full cluster
# build has already happened.
if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
  echo "❌ DISCORD_WEBHOOK_URL is not set — monitoring deploy would fail at the end."
  echo "   export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/<id>/<token>'"
  exit 1
fi

# Run scripts one by one
# create-cluster.sh waits for all nodes to be Ready before returning.
./scripts/create-cluster.sh
# No local build/load step — the api image is built and pushed to ghcr.io
# by .github/workflows/build-and-push.yml on every push to `release`, and
# deployed via ArgoCD (gitops/apps/kind-api/, dev + prod overlays) further below.
#
# deploy.sh only creates the namespaces and Secrets now; each namespace is
# applied first, so the old sleep-and-retry loop is no longer needed.
./scripts/deploy.sh
./scripts/deploy-metrics-server.sh
./scripts/deploy-monitoring.sh

echo "🚀 Installing ArgoCD and Argo Rollouts..."
./scripts/install-argocd.sh
./scripts/install-argo-rollouts.sh

echo "🚀 Registering GitOps Applications (kind-api-dev, kind-api)..."
kubectl apply -f gitops/argocd/app-of-apps.yaml

# install-argocd.sh/install-argo-rollouts.sh already wait for their own
# controllers to roll out, so the Application CRD is established by this
# point — this loop is waiting for ArgoCD to actually pull, sync, and get
# each app's pods healthy, not just for the apply above to succeed.
echo "⏳ Waiting for GitOps Applications to sync..."
for app in kind-api-dev kind-api; do
  synced=""
  for i in $(seq 1 30); do
    # `|| true` — a transient kubectl error here (e.g. right after apply,
    # before the object is fully registered) would otherwise trip `set -e`
    # and kill the whole script instead of letting this loop retry.
    synced=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null) || true
    if [ "$synced" = "Synced/Healthy" ]; then
      echo "✅ $app Synced/Healthy"
      break
    fi
    sleep 5
  done
  if [ "$synced" != "Synced/Healthy" ]; then
    echo "❌ $app did not reach Synced/Healthy in time (last status: ${synced:-unknown})"
    echo "   kubectl describe application $app -n argocd"
    exit 1
  fi
done