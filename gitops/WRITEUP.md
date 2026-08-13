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

## Reusing the sibling project's app was tempting, and deliberately deferred

The obvious upgrade — target the real `kind-api` app from `nodejs_with_kind`
instead of a toy `http-echo`, and drive canary analysis off its actual RED
metrics — was considered and set aside for two concrete reasons, not just
"scope creep worry": `kind-api:latest` is built locally and loaded directly
into the kind cluster's containerd (`kind load docker-image`), never
pushed to a registry, so there's nothing for a `Rollout` to *pull* by tag
the way true GitOps expects; and doing it anyway would re-couple two repos
that were deliberately kept independent (see `PLAN.md`'s scope decisions).
The canary/rollback mechanics built here are identical regardless of which
app they target, so this is a clean "next step," not something worth
having blocked on.
