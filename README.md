
---

## Requirements

- Docker
- Kubernetes (kind)
- kubectl
- Helm

---

## Setup Steps

### 1. Create Kind Cluster

run sripts run-all.sh to setup the kind cluster, building of image and loading image into the kind cluster.


### 1.1 Setting up alertmanager integration with discord
`export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/<id>/<token>'` before
running `run-all.sh` — `deploy-monitoring.sh` installs `kube-prometheus-stack`
(the Prometheus Operator) and creates a `discord-webhooks` Secret from this
env var directly in the cluster; the webhook is never written to a file.
See `monitoring/MIGRATION.md` for the full routing/inhibition setup this
wires up (pod-health alerts -> `k8s-triage-agent`'s Alertmanager bridge for
auto-triage, everything else -> Discord by severity).

### 2. Access the api
```bash
curl http://localhost/api
curl http://localhost/api/ready → readiness probe
curl http://localhost/api/health → liveness probe
curl http://localhost/api/error → simulate API error
```