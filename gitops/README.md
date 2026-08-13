# gitops/

A GitOps deployment pipeline layered on top of this repo's KIND cluster:
ArgoCD watches this directory, Kustomize overlays drive dev/prod config,
and Argo Rollouts demonstrates a canary rollout with automatic rollback on
a bad deploy.

Originally built as a separate standalone repo (`gitops-kind-demo`) and
merged in here so the whole cluster setup — app, monitoring, and GitOps —
lives in one place. See `PLAN.md` for the original rationale/build order
and `WRITEUP.md` for what building and running it actually surfaced
(CRD size limits, ArgoCD's polling delay, why a bad canary stalls silently,
why only a git-level fix survives `selfHeal`).

Currently demos against a small standalone `http-echo` app
(`apps/demo-app/`), not the `kind-api` app itself — see `WRITEUP.md`'s
last section for why that was deliberately deferred (no local image
registry yet, so there's nothing for a `Rollout` to pull by tag on a
`kind-api` code change).

## Structure

```
gitops/
  apps/demo-app/
    base/                 # Rollout (canary strategy) + Service for a tiny http-echo demo app
    overlays/dev/         # 2 replicas, text=dev-v1
    overlays/prod/        # base replica count, text=v1
  argocd/
    app-of-apps.yaml       # one file, two child Applications (dev + prod)
```

## Setup

### 0. Prerequisites
- The KIND cluster from this repo's own `run-all.sh` already running
- `kubectl` (uses `kubectl kustomize`, no separate `kustomize` binary needed)
- This repo pushed to GitHub — ArgoCD needs a real Git remote to watch,
  it can't sync from a local-only working tree

### 1. Sanity-check the manifests render correctly
```bash
kubectl kustomize gitops/apps/demo-app/overlays/dev
kubectl kustomize gitops/apps/demo-app/overlays/prod
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

**Done when:** `kubectl get applications -n argocd` shows `demo-app-dev` and
`demo-app-prod` both `Synced`/`Healthy`, and
`kubectl get pods -n demo-app-prod` shows 4 running `demo-app` pods.

### 4. Canary / rollback demo
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
