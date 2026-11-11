#!/usr/bin/env bash
# metrics-server — powers `kubectl top` and the triage agent's resource checks.
#
# KIND needs --kubelet-insecure-tls: kubelet serving certs are self-signed and
# not valid for the address metrics-server dials, so without this the pods run
# but every scrape fails with an x509 error and `kubectl top` stays empty.
set -euo pipefail

# Pinned so respins are reproducible; override to upgrade deliberately.
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.9.1}"

echo "📊 Installing metrics-server ${METRICS_SERVER_VERSION}..."
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

# Idempotent: adding the same arg twice would make metrics-server fail to start,
# so only patch when it isn't already present.
if kubectl get deployment metrics-server -n kube-system \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--kubelet-insecure-tls'; then
  echo "   --kubelet-insecure-tls already set, skipping patch"
else
  kubectl patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi

kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s

# The API registers before it has scraped anything, so `kubectl top` can return
# "metrics not available yet" for a little while after the rollout completes.
echo "   waiting for first metrics scrape..."
for _ in $(seq 1 30); do
  if kubectl top nodes >/dev/null 2>&1; then
    echo "✅ metrics-server ready"
    exit 0
  fi
  sleep 5
done

echo "⚠️  metrics-server rolled out but 'kubectl top nodes' is still empty."
echo "    Check: kubectl -n kube-system logs deployment/metrics-server"
