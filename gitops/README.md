# gitops/

The GitOps deployment pipeline for this repo's API (`kind-api`): ArgoCD
watches this directory, Kustomize overlays turn one set of manifests into
a **dev** and a **prod** environment, and Argo Rollouts runs canary
releases, with prod's canary aborting automatically when Prometheus sees
errors.

Originally built as a separate standalone repo (`gitops-kind-demo`) around
a toy `http-echo` app, then merged in here. The toy app has since been
removed: `kind-api` now demonstrates everything it did (canaries,
dev/prod overlays, Git-based rollback) on the real API, plus
metrics-driven rollback. See `PLAN.md` for the original rationale/build
order and `WRITEUP.md` for what building and running it surfaced (CRD size
limits, ArgoCD's polling delay, why a bad canary stalls silently, why only
a git-level fix survives `selfHeal`).

## How it fits together

- **Image:** built and pushed to `ghcr.io` by
  `.github/workflows/build-and-push.yml` on every push to `release`, which
  then commits the new `:<git-sha>` tag into `apps/kind-api/base/rollout.yaml`.
  There's exactly one way the image gets built and deployed.
- **Manifests:** everything the API needs (Rollout, Service, Ingress,
  ConfigMap, RBAC, HPA) is written once in `apps/kind-api/base/`. Each
  overlay changes only what differs for its environment.
- **Secret:** the one exception. `scripts/deploy.sh` creates `api-secret`
  in both namespaces so credentials stay out of what ArgoCD syncs from Git
  (Sealed Secrets / External Secrets in a real setup).
- **Scaling:** the HPA targets the `Rollout` directly, and both
  Applications ignore drift on the Rollout's `/spec/replicas` so ArgoCD's
  `selfHeal` doesn't undo the autoscaler.

## Structure

```
gitops/
  apps/
    kind-api/
      base/                    # shared manifests, no namespace, no env-specific values
        rollout.yaml           # canary steps 25 → 50 → 75 → 100%, 30s pauses
        service.yaml, ingress.yaml, configmap.yaml, rbac.yaml, hpa.yaml
        kustomization.yaml
      overlays/
        dev/kustomization.yaml       # namespace kind-api-dev, see table below
        prod/kustomization.yaml      # namespace kind-demo, see table below
        prod/analysis-template.yaml  # aborts the canary if the 5xx ratio > 5%
  argocd/
    app-of-apps.yaml           # kind-api-dev → overlays/dev, kind-api → overlays/prod
```

## What each overlay changes

| | dev (`kind-api-dev`) | prod (`kind-api`) |
|---|---|---|
| Namespace | `kind-api-dev` | `kind-demo` |
| URL | `http://localhost/dev/api` | `http://localhost/api`, NodePort `30000` |
| `MODE` / `ENV` | `development` / `dev` | `production` / `prod` |
| Starting replicas / HPA range | 1 / 1–2 | 2 / 2–10 |
| Canary | one 50% step, 10s pause | 25 → 50 → 75%, 30s pauses |
| Error-rate analysis | none | aborts if > 5% of requests are 5xx |

See the result for either environment without a cluster:

```bash
kubectl kustomize gitops/apps/kind-api/overlays/dev
kubectl kustomize gitops/apps/kind-api/overlays/prod
```

**Note:** both overlays use the image tag from the base, so a new build
rolls out to dev and prod at the same time (dev just finishes faster). A
natural next step is promotion: CI bumps only the dev overlay's
`images:` tag, and prod gets bumped by a separate, deliberate commit or PR.

## Setup

`run-all.sh` runs steps 2 and 3 below automatically as part of cluster
bring-up. The steps below are for running or re-running the GitOps layer
on its own (e.g. if `argocd`/`argo-rollouts` got wiped without a full
cluster respin).

### 0. Prerequisites
- The KIND cluster from this repo's own `run-all.sh` already running
- `kubectl` (uses `kubectl kustomize`, no separate `kustomize` binary needed)
- This repo pushed to GitHub — ArgoCD needs a real Git remote to watch,
  it can't sync from a local-only working tree
- At least one push to `release` touching `src/`/`Dockerfile`/the package
  files, to trigger `.github/workflows/build-and-push.yml` and produce a
  real image tag. (No manual "set package visibility" step needed in
  practice — the first image pushed here was already pullable anonymously;
  see `WRITEUP.md` if a private-by-default GHCR package ever does need to
  be made public.)

### 1. Sanity-check the manifests render correctly
```bash
kubectl kustomize gitops/apps/kind-api/overlays/dev
kubectl kustomize gitops/apps/kind-api/overlays/prod
```

### 2. Install ArgoCD and Argo Rollouts
```bash
./scripts/install-argocd.sh
./scripts/install-argo-rollouts.sh
```
Both assume the KIND cluster already exists — they only install their
respective controllers into it. `install-argocd.sh` prints the admin
login/port-forward commands once done:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8081:443
```
(8081, because host port 8080 is where Alertmanager sends pod alerts to the
k8s-triage-agent bridge.)

### 3. Create the namespaces/Secrets and register the app-of-apps
```bash
./scripts/deploy.sh
kubectl apply -f gitops/argocd/app-of-apps.yaml
```

**Done when:** `kubectl get applications -n argocd` shows `kind-api-dev`
and `kind-api` both `Synced`/`Healthy`, and both of these respond:
```bash
curl http://localhost/dev/api/version
curl http://localhost/api/version
```

**Upgrading a cluster that still has the old toy app?** `kubectl apply`
doesn't delete Applications that were removed from the file. Clean them up
with:
```bash
kubectl delete application demo-app-dev demo-app-prod -n argocd
kubectl delete namespace demo-app-dev demo-app-prod
```

## Canary / rollback demo

Push a code change to `src/` on `release` — that's the *only* manual step.
The workflow builds and pushes a new
`ghcr.io/barnbarn96/nodejs_with_kind:<git-sha>` image, then commits that
tag into `apps/kind-api/base/rollout.yaml` and pushes it back (as
`github-actions[bot]`). ArgoCD picks up that commit and Argo Rollouts
walks each environment's canary steps.

```bash
kubectl get rollout api -n kind-api-dev -w   # dev: done in ~10s
kubectl get rollout api -n kind-demo -w      # prod: ~90s, with analysis
curl http://localhost/api/version            # confirm prod serves the new version
```

### Automatic rollback in prod

Prod's `api-error-rate` analysis queries Prometheus every 30s during the
rollout and **aborts automatically** if more than 5% of requests return
5xx. To see it, start a rollout and generate errors against prod:

```bash
for i in $(seq 1 30); do curl -s http://localhost/api/error >/dev/null; sleep 1; done
kubectl get analysisrun -n kind-demo
kubectl get rollout api -n kind-demo   # Degraded / aborted, stable version still serving
```

### Rolling back for good

`git revert <bad-sha>` on the *code* commit and push. CI builds and
auto-bumps a revert image the same way, and ArgoCD syncs it — see
`WRITEUP.md` for why a manual `kubectl`/UI-only rollback would get fought
by `selfHeal` and doesn't actually stick.
