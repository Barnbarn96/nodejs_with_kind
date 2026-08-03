#!/bin/bash

# Checked up front, not at the last step: deploy-monitoring.sh needs this to
# substitute the webhook placeholder, and failing there means a full cluster
# build has already happened.
if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
  echo "❌ DISCORD_WEBHOOK_URL is not set — monitoring deploy would fail at the end."
  echo "   export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/<id>/<token>'"
  exit 1
fi

# Run scripts one by one
./scripts/create-cluster.sh
./scripts/build-image.sh
./scripts/load-image.sh
# Wait for cluster to be ready
sleep 10  
# Retry deploy.sh up to 3 times
echo "🚀 Starting deployment with retry logic..."
for i in {1..3}; do
  echo "Deployment attempt $i/3..."
  if ./scripts/deploy.sh; then
    echo "✅ Deployment successful!"
    break
  else
    if [ $i -lt 3 ]; then
      echo "⚠️  Deployment failed, retrying in 5 seconds..."
      sleep 5
    else
      echo "❌ Deployment failed after 3 attempts"
      exit 1
    fi
  fi
done
./scripts/deploy-metrics-server.sh
./scripts/deploy-monitoring.sh