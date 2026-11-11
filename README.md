# nodejs_with_kind

A production-style Kubernetes setup for a small Node.js API, running
entirely on a local [KIND](https://kind.sigs.k8s.io/) cluster:

- **App:** Express API exposing RED metrics (`http_requests_total`,
  `http_errors_total`, `http_request_duration_seconds`) via `prom-client`,
  with graceful shutdown and fail-fast config validation.
- **Delivery:** GitHub Actions tests the app, validates every manifest,
  builds a non-root distroless image to GHCR and bumps the tag in Git.
  ArgoCD syncs it and Argo Rollouts runs a canary that **aborts
  automatically** if Prometheus sees the 5xx ratio go above 5%.
- **Monitoring:** `kube-prometheus-stack` (Prometheus Operator) with a
  `ServiceMonitor`, `PrometheusRule`s for pod health and API errors, and an
  `AlertmanagerConfig` that sends pod-failure alerts to the
  [k8s-triage-agent](#k8s-triage-agent) bridge and everything else to
  Discord by severity.
- **Scaling:** HPA on CPU against the Argo Rollout, with metrics-server.

```
push to release ──► CI: tests + kubeconform ──► build image ──► bump tag in Git
                                                                     │
                       ArgoCD (app-of-apps) ◄────────────────────────┘
                              │
                     Argo Rollouts canary 25→50→75→100%
                              │   ▲
                              ▼   │ AnalysisRun: 5xx ratio < 5%?
                       kind-api pods ──► Prometheus ──► Alertmanager
                                                           ├─► Discord
                                                           └─► triage bridge (:8080)
```

---

## Requirements

- Docker
- [kind](https://kind.sigs.k8s.io/), kubectl, Helm
- A Discord webhook URL (for alerts)

---

## Setup

### 1. Bring up everything

```bash
export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/<id>/<token>'
./scripts/run-all.sh
```

`run-all.sh` creates the cluster, installs ingress-nginx, metrics-server,
`kube-prometheus-stack`, Grafana, ArgoCD and Argo Rollouts, then registers
the ArgoCD Applications and waits for them to be `Synced/Healthy`. All
third-party versions are pinned in the scripts and can be overridden with
env vars (e.g. `ARGOCD_VERSION`, `KUBE_PROM_STACK_VERSION`).

The Discord webhook is created as a Secret directly in the cluster and is
never written to a file. See `monitoring/MIGRATION.md` for the full
routing/inhibition setup.

### 2. Access the API

```bash
curl http://localhost/api
curl http://localhost/api/version
curl http://localhost/api/ready    # readiness probe
curl http://localhost/api/health   # liveness probe
curl http://localhost/api/error    # simulate an API error (counts as a 5xx)
```

### 3. GitOps pipeline (ArgoCD + Argo Rollouts)

See [`gitops/README.md`](gitops/README.md) for how the pipeline works and
how to demo a canary being aborted, and `gitops/WRITEUP.md` for the
design story.

### Run the tests locally

```bash
npm ci
npm test
```

---

## Repository layout

| Path | What it is |
|---|---|
| `src/` | The API |
| `test/` | Smoke tests (Node's built-in test runner) |
| `gitops/apps/kind-api/` | All of the API's Kubernetes resources, synced by ArgoCD |
| `gitops/apps/demo-app/` | A tiny canary demo app with dev/prod Kustomize overlays |
| `gitops/argocd/` | The app-of-apps ArgoCD Applications |
| `manifests/` | The only resources applied by hand: the namespace and the Secret |
| `monitoring/` | ServiceMonitor, PrometheusRules, AlertmanagerConfig, Grafana values |
| `scripts/` | Cluster bring-up and teardown |
| `.github/workflows/` | CI (tests + manifest validation) and image build/deploy |

## k8s-triage-agent

Pod-health alerts (`PodCrashLooping`, `PodImagePullFailing`,
`PodOOMKilled`, `PodUnschedulable`, `PodNotReady`) are routed to
`http://host.docker.internal:8080/alert`, where the separate
k8s-triage-agent project receives them, diagnoses the failing pod, and
posts the root cause to Discord. Keep host port 8080 free for it.
