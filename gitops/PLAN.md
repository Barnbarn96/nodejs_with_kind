# GitOps Deployment Pipeline (ArgoCD + Kustomize on KIND)

## Goal
Standalone GitOps pipeline project for the resume — demonstrates continuous
deployment, Kustomize environment overlays, and canary rollout/rollback using
Argo Rollouts. Runs on the same local KIND cluster as other side projects,
but is a fully separate, self-contained app (no dependency on the k8s
triage agent).

## Why this project
- One of the most commonly probed topics in SRE / Platform Engineer
  interviews ("walk me through your deployment pipeline", "how do you
  handle rollbacks").
- Reuses existing KIND cluster + K8s/Terraform background.
- Produces a clean, demoable repo — good as a 2-minute live demo in
  interviews (bad image tag → automatic rollback).

## Scope decisions
- Kept isolated from the k8s-triage-agent project (separate namespace,
  separate app) — no coupling for now.
- Uses a small standalone demo app (not the triage agent) so replica count
  and traffic-shifting can be controlled cleanly for canary/rollback demos.

## Repo structure
```
gitops-kind-demo/
  apps/
    demo-app/
      base/
      overlays/dev/
      overlays/prod/
  argocd/
    app-of-apps.yaml
```

## Build order
1. **Install ArgoCD in KIND**
   - Own namespace (e.g. `argocd`), isolated from other workloads in the
     cluster.
2. **Create the demo app**
   - Simple multi-replica web service (even a "hello world" with a visible
     version number is enough).
   - Kustomize `base/` + `overlays/dev/` + `overlays/prod/`.
3. **Register as an ArgoCD Application**
   - Point ArgoCD at the Git repo.
   - Verify auto-sync works on `git push`.
4. **Add Argo Rollouts**
   - Configure canary strategy on the demo app.
   - Demo: push a bad version → automatic/manual rollback.

## Interview story
- Frame as: "I built and run a GitOps pipeline for my own infrastructure —
  ArgoCD watches my repo, auto-syncs changes, and I can demo a canary
  rollout with automatic rollback on a bad deploy."
- Pairs well with other SRE-adjacent projects (reactive: triage/diagnosis
  vs proactive: GitOps/deployment control) without needing to literally
  combine the codebases.
