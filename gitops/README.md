# gitops/

A GitOps deployment pipeline layered on top of this repo's KIND cluster:
ArgoCD watches this directory, Kustomize overlays drive dev/prod config,
and Argo Rollouts demonstrates a canary rollout with automatic rollback on
a bad deploy — for both a small standalone demo app and this repo's own
`kind-api` app.

Originally built as a separate standalone repo (`gitops-kind-demo`) and
merged in here so the whole cluster setup — app, monitoring, and GitOps —
lives in one place. See `PLAN.md` for the original rationale/build order
and `WRITEUP.md` for what building and running it actually surfaced
(CRD size limits, ArgoCD's polling delay, why a bad canary stalls silently,
why only a git-level fix survives `selfHeal`, and why `kind-api` wasn't
wired in immediately — see below for how that got resolved).

## `kind-api` is now GitOps-managed too

`manifests/deployment.yaml` is gone — `kind-api` is now a `Rollout`
(`apps/kind-api/rollout.yaml`), built and pushed to `ghcr.io` by
`.github/workflows/build-and-push.yml` on every push to `release`, and
deployed by ArgoCD like everything else here. `scripts/build-image.sh` /
`load-image.sh` (local build + `kind load docker-image`, bypassing any
registry) are gone too — there's now exactly one way the app image gets
built and deployed, not a local-only path and a GitOps path that could
drift apart.

`scripts/deploy.sh` still applies everything else the app needs (RBAC,
`ConfigMap`, `Secret`, `Service`, HPA, Ingress, PV/PVC) — just not the
workload resource itself anymore, since ArgoCD owns that now and a second
controller applying a plain `Deployment` with the same pod selector would
fight it for ownership.

## Structure

```
gitops/
  apps/
    demo-app/
      base/                 # Rollout (canary strategy) + Service for a tiny http-echo demo app
      overlays/dev/         # 2 replicas, text=dev-v1
      overlays/prod/        # base replica count, text=v1
    kind-api/
      rollout.yaml           # this repo's real app, same canary strategy
  argocd/
    app-of-apps.yaml         # one file, three child Applications
```

## Setup

### 0. Prerequisites
- The KIND cluster from this repo's own `run-all.sh` already running
- `kubectl` (uses `kubectl kustomize`, no separate `kustomize` binary needed)
- This repo pushed to GitHub — ArgoCD needs a real Git remote to watch,
  it can't sync from a local-only working tree
- For `kind-api` specifically: at least one push to `release` touching
  `src/`/`Dockerfile`/the package files, to trigger
  `.github/workflows/build-and-push.yml` and produce a real image tag —
  the `Rollout` bootstraps against `:latest`, which won't exist until
  that first build runs. (No manual "set package visibility" step needed
  in practice — the first image pushed here was already pullable
  anonymously; see `WRITEUP.md` if a private-by-default GHCR package
  ever does need to be made public.)

### 1. Sanity-check the manifests render correctly
```bash
kubectl kustomize gitops/apps/demo-app/overlays/dev
kubectl kustomize gitops/apps/demo-app/overlays/prod
kubectl kustomize gitops/apps/kind-api
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
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

### 3. Register the app-of-apps
```bash
kubectl apply -f gitops/argocd/app-of-apps.yaml
```

**Done when:** `kubectl get applications -n argocd` shows `demo-app-dev`,
`demo-app-prod`, and `kind-api` all `Synced`/`Healthy`, and
`kubectl get pods -n kind-demo` shows the `api` pods running the `ghcr.io`
image (not `kind-api:latest` anymore).

### 4. Canary / rollback demo — demo-app
Edit `apps/demo-app/base/rollout.yaml`'s container `args`, commit, push —
ArgoCD auto-syncs and Argo Rollouts walks the canary steps
(`setWeight: 25 → pause → 50 → pause → 75 → pause → 100`) automatically.

Push a genuinely broken version (e.g. `-listen=:9999` so the readiness
probe checking port 5678 can never pass) to see it stall instead of
completing — `kubectl get rollout demo-app -n demo-app-prod` stops
advancing, and the bad pod sits at `0/1 Ready` indefinitely.

To roll back: `git revert <bad-sha>` and push. ArgoCD auto-syncs the
reverted manifest and Argo Rollouts aborts the bad canary automatically —
see `WRITEUP.md` for why a manual `kubectl`/UI-only rollback would get
fought by `selfHeal` and doesn't actually stick.

### 5. Canary / rollback demo — kind-api (the real thing)
Push a code change to `src/` on `release` — that's the *only* manual step.
The workflow builds and pushes a new
`ghcr.io/barnbarn96/nodejs_with_kind:<git-sha>` image, then commits that
tag straight into `gitops/apps/kind-api/rollout.yaml` and pushes it back
(as `github-actions[bot]`) — no manual YAML editing needed. ArgoCD picks
up that commit and Argo Rollouts walks the same canary steps as
`demo-app`, backed by the app's own real `/health`/`/ready`/`/version`
endpoints instead of a toy `http-echo` one.

```bash
kubectl get rollout api -n kind-demo -w
curl http://localhost/api/version   # confirm it's serving the new version
```

Same rollback mechanism (`git revert` on the *code* commit — CI will
build and auto-bump a revert image the same way) applies.
