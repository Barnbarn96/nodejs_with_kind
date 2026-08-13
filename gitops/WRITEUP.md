# Notes: building a GitOps pipeline that actually gets exercised end-to-end

A short write-up of what building and *running* this surfaced — several
things only show up once you push a real bad deploy through the pipeline,
not when reading the ArgoCD/Argo Rollouts docs.

## Large CRDs break `kubectl apply`'s default annotation strategy

Installing ArgoCD via its official `install.yaml` failed immediately:

```
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

Default `kubectl apply` stores the entire applied config in a
`last-applied-configuration` annotation for future 3-way diffs. ArgoCD's
CRDs have rich enough OpenAPI schemas that this blows past etcd's 256KiB
annotation limit. The fix is `--server-side` apply, which tracks ownership
via managed fields instead of that annotation — but switching to it after
an already-partially-applied client-side attempt then hit a second error:
field-manager conflicts on resources the failed attempt had already
created. `--force-conflicts` resolved it, safe here since nothing else
legitimately co-manages those fields. Both `install-argocd.sh` and
`install-argo-rollouts.sh` use `--server-side --force-conflicts` from the
start now, not just as a recovery step.

## ArgoCD doesn't watch git in real time — it polls

Every push during testing took up to 3 minutes to be noticed (`Application`
status stayed on the old revision long after the commit landed and was
confirmed on `origin/main`). ArgoCD's `timeout.reconciliation` setting
defaults to 180s; without a configured Git webhook pushing an immediate
refresh signal, that's the ceiling on how fast it reacts. Real deployments
wire up a webhook from GitHub/GitLab to the ArgoCD server's `/api/webhook`
endpoint for near-instant sync — not possible here, since this ArgoCD
instance is only reachable via local port-forward, not from GitHub's
delivery servers. The `argocd.argoproj.io/refresh: hard` annotation (same
as the UI's "Refresh" button) is the manual equivalent, used throughout
testing instead of waiting out the timer.

## The canary genuinely stalls — it doesn't fail loudly

Pushing a deliberately broken version (`http-echo` listening on the wrong
port, so its own readiness probe can never pass) didn't produce an error
anywhere. `kubectl get rollout` just... stopped updating. `UP-TO-DATE`
stayed at `1` of `4`, `AVAILABLE` stayed one short of desired, and the new
pod sat at `0/1 Ready` indefinitely. `kubectl describe rollout` was the
tell — no new `RolloutStepCompleted`/`RolloutPaused` events for several
minutes, versus the steady drumbeat of them during a healthy rollout. The
canary strategy used here (`setWeight`/`pause` steps, no `AnalysisTemplate`)
doesn't *detect* a bad deploy and abort it — it just can't satisfy the
next step's availability requirement, so it sits there until someone
notices. A real production setup would wire an `AnalysisTemplate` against
Prometheus to auto-abort on a bad error rate instead of stalling silently;
noted as a deliberate scope decision to keep this repo standalone (see
`PLAN.md`) rather than couple it to the sibling monitoring project.

## `git revert` fixes it — but only because self-heal is watching

The rollback story turned out to have a sharper edge than expected.
`Application.spec.syncPolicy.automated.selfHeal: true` means ArgoCD
continuously reconciles the *live cluster* to match whatever git currently
says, not just on push. That has a real consequence for incident response:
manually rolling back via the ArgoCD UI ("History and Rollback" → pick a
prior revision) works for a moment, but self-heal will detect the drift
between the live cluster and the still-bad git revision, and quietly
resync back to the bad version on its next reconcile pass. The only fix
that *sticks* is one that changes what git says — `git revert <bad-sha>`
(a real PR in production, `HEAD` here since this is a solo demo repo) and
push. Once that landed, ArgoCD synced the reverted manifest, Argo Rollouts
saw the pod template match the last-known-good revision, and the bad
canary pod was scaled down automatically — no `kubectl` touched during the
actual recovery. That "GitOps means the manual fix doesn't stick, only the
git fix does" behavior is worth being able to explain, not just demo.

## Reusing the sibling project's app: deferred, then done properly

The obvious upgrade — target the real `kind-api` app instead of a toy
`http-echo`, and drive it off a real CI/registry pipeline — was initially
deferred for two reasons: `kind-api:latest` was built locally and loaded
directly into containerd (`kind load docker-image`), never pushed to a
registry, so there was nothing for a `Rollout` to *pull* by tag; and doing
it meant re-coupling two repos that had been deliberately kept
independent. Both reasons evaporated once the decision was made to merge
`gitops-kind-demo` into this repo outright (see the section below) — at
that point "keep them separate" was no longer the goal, and the registry
gap became the actual next problem to solve, not a reason to defer.

The fix: a GitHub Actions workflow (`.github/workflows/build-and-push.yml`)
builds the existing `Dockerfile` and pushes to `ghcr.io/barnbarn96/nodejs_with_kind`
on every push to `release` that touches `src/`/`Dockerfile`/the package
files, tagged with both `:latest` and the exact `:<git-sha>`.
`manifests/deployment.yaml` became `gitops/apps/kind-api/rollout.yaml` —
same canary steps as `demo-app`, but backed by the app's own real
`/health`/`/ready` probes instead of a synthetic one. `scripts/deploy.sh`
still applies everything else the app needs (RBAC, config, storage,
networking) but not the workload resource itself anymore, since ArgoCD
owns that now — a plain `Deployment` still fighting an `Rollout` for the
same `app: api` pods was a real, confirmed conflict, not a theoretical
one (had to `kubectl delete deployment api` before the `Rollout` could
take over cleanly).

One assumption turned out to be wrong: GHCR images are widely documented
as private-by-default even on a public repo, requiring a manual
"Packages → set visibility to Public" step before the cluster can pull
without a pull secret. In practice, the first image pushed here was
already pullable anonymously (`docker pull` with no login succeeded
immediately) — worth verifying with an actual unauthenticated pull rather
than trusting the docs, since the manual step turned out to be
unnecessary for this repo's case.

## Closing the loop: CI commits the new tag back, not just the image

Bumping `rollout.yaml`'s image tag by hand after every build defeats the
point of "push code, get a deploy" — so the same workflow that builds and
pushes the image now also `sed`s the new `:<git-sha>` into
`gitops/apps/kind-api/rollout.yaml`, commits as `github-actions[bot]`, and
pushes back to `release`. The alternative — ArgoCD Image Updater, a
dedicated controller that watches the registry and updates `Application`s
automatically — is the more "proper" tool for this, but is real
additional infrastructure to run and configure for what's a small need
here; a CI step that commits a one-line change is simpler to reason about
and to explain.

The obvious risk with a bot commit pushing back to the same branch a
push-triggered workflow watches is an infinite loop — solved for free
here, not by extra logic: the bot's commit only touches `rollout.yaml`,
which isn't in the workflow's `paths:` filter (`Dockerfile`, `src/**`,
`package*.json`), so it doesn't re-trigger the build. `[skip ci]` in the
bot's commit message is a second, redundant layer on top of that.

## `main`, `master`, and why the ArgoCD Applications point at neither by that name

`origin/main` on this repo turned out to be stale, unrelated content from
before any of this session's real work began — discovered when
`Application.spec.source.targetRevision: HEAD` (which resolves to
whatever the remote's default branch is) meant ArgoCD was trying to sync
`gitops/apps/demo-app/overlays/dev` from a repo revision that had no
`gitops/` directory at all. Fixing `main` in place (force-pushing real
content over it) was considered and explicitly rejected — instead, the
branch holding all real work (`master`) was renamed to `release`, `main`
was left completely untouched, and every `Application`'s `targetRevision`
was pinned to `release` explicitly rather than left as `HEAD`. Small
lesson worth remembering: `HEAD` in an `Application` source is only as
trustworthy as whatever the remote's default branch happens to be — worth
pinning explicitly rather than assuming it points where you think.

## The kind API server port drift, and the one-line fix

The single most recurring interruption all session, across every repo
this cluster hosts: `kind create cluster` binds the API server to a
random free host port every time, but the kubeconfig on disk keeps
whatever port was current when it was last written. Every cluster
respin — intentional or from a Docker Desktop restart — silently broke
`kubectl` (and the k8s-triage-agent bridge, and any other already-running
process holding an old port) with `connection refused`, fixed each time
by re-running `kind export kubeconfig --name inter`. The actual fix was a
single line: `networking.apiServerPort: 6443` in `kind-cluster.yaml`
pins the port permanently, so it never changes across respins again. It's
a one-line config option that would have saved a meaningful fraction of
this session's total debugging time — worth reaching for immediately on
any new kind cluster, not just after getting bitten by it repeatedly.
