
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
replace the '${DISCORD_WEBHOOK_URL}' in ./monitoring/prometheus-values.yaml with the discord webhook uri.

### 2. Access the api
```bash
curl http://localhost/api
curl http://localhost/api/ready → readiness probe
curl http://localhost/api/health → liveness probe
curl http://localhost/api/error → simulate API error



