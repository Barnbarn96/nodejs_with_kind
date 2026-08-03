# Migration: `prometheus-community/prometheus` → Prometheus Operator (CRDs)

Not started yet — this is the plan, written up before touching anything so
the migration itself can be reviewed/discussed first.

## Why

Today, `monitoring/prometheus-values.yaml` is a single Helm values file for
the plain `prometheus-community/prometheus` chart. Alert rules
(`serverFiles.alerting_rules.yml`) and Alertmanager routing/receivers
(`alertmanager.config`) are both just YAML blobs the chart templates into a
ConfigMap/Secret — no CRDs, no controller, no independent lifecycle per rule
group.

The Prometheus Operator (installed via the `kube-prometheus-stack` chart)
replaces that with actual Kubernetes objects — `PrometheusRule` for rules,
`AlertmanagerConfig` for routing — reconciled by a controller. This is the
pattern most real clusters use, and it fits this repo's existing philosophy
(`tools.py` as k8s-triage-agent's "single source of truth", per WRITEUP.md)
better than one big values file: `pod-health` rules become their own
manifest with their own lifecycle, separate from the Prometheus deployment
itself.

## What changes, at a glance

| Today | After |
|---|---|
| `prometheus-community/prometheus` chart | `kube-prometheus-stack` chart |
| `serverFiles.alerting_rules.yml` in values | `PrometheusRule` CR(s) |
| `alertmanager.config` in values | `AlertmanagerConfig` CR + `Alertmanager` CR |
| `extraScrapeConfigs` (annotation-based scrape) | `ServiceMonitor` CR |
| `--set-string` webhook substitution in `deploy-prometheus.sh` | `Secret` + `secretKeyRef` in `AlertmanagerConfig` |
| `helm upgrade --install prom prometheus-community/prometheus ...` | `helm upgrade --install prom prometheus-community/kube-prometheus-stack ...` |

## Step-by-step

### 1. Install `kube-prometheus-stack` alongside the current release

Don't overwrite the existing `prom` release in place — `kube-prometheus-stack`
is a different chart with a different object model (it also bundles its own
Grafana, which would collide with the separately-installed `grafana` release
in `deploy-monitoring.sh`). Install it under a new release name first, verify
it works, then decommission the old one.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prom-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.enabled=false   # keep using the existing standalone grafana release
```

**Gotcha:** `kube-prometheus-stack` installs CRDs (`PrometheusRule`,
`ServiceMonitor`, `PodMonitor`, `Alertmanager`, `AlertmanagerConfig`,
`Prometheus`) cluster-wide on first install. On a KIND cluster that's fine;
just don't `helm uninstall` it casually later without checking nothing else
depends on those CRDs.

### 2. Convert the scrape config to a `ServiceMonitor`

Today, scraping the API relies on
`prometheus.io/scrape`/`prometheus.io/port`/`prometheus.io/path` pod
annotations (`manifests/deployment.yaml:15-18`) plus a static
`extraScrapeConfigs` entry pointing at
`api.kind-demo.svc.cluster.local:80`. The Prometheus Operator's Prometheus
CR does **not** scrape by annotation by default — it only picks up targets
matching its `serviceMonitorSelector`. Two things need to change:

- `manifests/service.yaml` needs a label the `ServiceMonitor` can select on
  (it currently has none beyond the implicit `app: api` via `selector`, but
  that's the pod selector, not a label on the Service object itself — add
  e.g. `metadata.labels.app: api` to the Service).
- Add a `ServiceMonitor`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kind-api
  namespace: monitoring   # or kind-demo, matching serviceMonitorSelectorNilUsesHelmValues
  labels:
    release: kube-prom-stack   # must match the chart's serviceMonitorSelector
spec:
  namespaceSelector:
    matchNames: ["kind-demo"]
  selector:
    matchLabels:
      app: api
  endpoints:
    - port: http          # named port on the Service, not a raw number
      path: /metrics
```

`manifests/service.yaml`'s port will need a `name: http` added, since
`ServiceMonitor.endpoints[].port` matches by port *name*, not number.

### 3. Convert `serverFiles.alerting_rules.yml` to `PrometheusRule` CRs

Split the two existing rule groups into their own manifests — this is the
main point of the migration, so keep them separable:

`monitoring/rules/api-alerts.yaml`:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: api-alerts
  namespace: monitoring
  labels:
    release: kube-prom-stack
spec:
  groups:
    - name: api-alerts
      rules:
        - alert: HTTPErrorsPresent
          expr: sum(rate(http_errors_total[5m])) > 0
          for: 30s
          labels:
            severity: warning
          annotations:
            summary: "HTTP errors detected"
            description: 'Error rate: {{ $value | printf "%.3f" }}/s over the last 5m'
```

`monitoring/rules/pod-health.yaml`:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: pod-health
  namespace: monitoring
  labels:
    release: kube-prom-stack
spec:
  groups:
    - name: pod-health
      rules:
        - alert: PodCrashLooping
          expr: kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} > 0
          for: 30s
          labels: { severity: critical }
          annotations:
            summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} is crash-looping"
            description: "Container {{ $labels.container }} is in CrashLoopBackOff."
        # ... PodImagePullFailing, PodNotReady, PodOOMKilled, PodUnschedulable,
        # PodRestartingRepeatedly — copied verbatim from the current
        # `pod-health` group in prometheus-values.yaml, no expression changes.
```

Everything currently under `pod-health` and `api-alerts` in
`prometheus-values.yaml:187-283` moves here unmodified — this step is a
lift, not a rewrite of the rules themselves.

### 4. Convert Alertmanager routing to `AlertmanagerConfig`

This is the part with real semantic differences, not just a reformat.

**Webhook secret, not `--set-string`:** create a real `Secret` instead of
substituting the URL via Helm CLI args at deploy time:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: discord-webhooks
  namespace: monitoring
stringData:
  default-url: "$DISCORD_WEBHOOK_URL"   # still injected at deploy time, just via a Secret
```

Referenced from the `AlertmanagerConfig` receiver via `discordConfigs[].apiURL.key`/`.name`
instead of a literal `webhook_url` field.

**Routing + receivers + inhibition**, translated from
`prometheus-values.yaml:60-175`:

```yaml
apiVersion: monitoring.coreos.com/v1alpha1   # inhibitRules requires v1alpha1 (or newer, check chart's CRD version)
kind: AlertmanagerConfig
metadata:
  name: triage-routing
  namespace: monitoring
  labels:
    release: kube-prom-stack   # must match alertmanagerConfigSelector
spec:
  route:
    groupBy: ["alertname", "namespace", "pod"]
    groupWait: 10s
    groupInterval: 10s
    repeatInterval: 12h
    routes:
      - matchers:
          - name: alertname
            matchType: "=~"
            value: "Pod(CrashLooping|ImagePullFailing|NotReady|OOMKilled|Unschedulable)"
        receiver: triage-bridge
      - matchers:
          - name: alertname
            value: PodRestartingRepeatedly
        receiver: noop
      - matchers: [{ name: severity, value: warning }]
        receiver: discord-warnings
      - matchers: [{ name: severity, value: critical }]
        receiver: discord-critical
  receivers:
    - name: triage-bridge
      webhookConfigs:
        - url: "http://host.docker.internal:8080/alert"
          sendResolved: false
    - name: noop
    - name: discord-warnings
      discordConfigs:
        - apiURL: { name: discord-webhooks, key: default-url }
          sendResolved: true
    - name: discord-critical
      discordConfigs:
        - apiURL: { name: discord-webhooks, key: default-url }
          sendResolved: true
  inhibitRules:
    - sourceMatch: [{ name: alertname, value: PodCrashLooping }]
      targetMatch: [{ name: alertname, value: PodNotReady }]
      equal: ["namespace", "pod"]
    - sourceMatch: [{ name: alertname, value: PodImagePullFailing }]
      targetMatch: [{ name: alertname, value: PodNotReady }]
      equal: ["namespace", "pod"]
    - sourceMatch: [{ name: alertname, value: PodOOMKilled }]
      targetMatch: [{ name: alertname, value: PodNotReady }]
      equal: ["namespace", "pod"]
    - sourceMatch: [{ name: alertname, value: PodRestartingRepeatedly }]
      targetMatch: [{ name: alertname, value: PodNotReady }]
      equal: ["namespace", "pod"]
```

**Gotchas specific to this repo:**

- `AlertmanagerConfig.spec.inhibitRules` needs a recent-enough Prometheus
  Operator version — older CRD versions didn't support inhibition at all in
  `AlertmanagerConfig` (it used to be Alertmanager-CR-global only). Check
  `kube-prometheus-stack`'s bundled operator version before assuming this
  works verbatim; if it doesn't, inhibition has to live in the top-level
  `Alertmanager` CR's `spec.alertmanagerConfiguration` instead.
- `AlertmanagerConfig` is namespaced and, by default, only applies to alerts
  originating from rules in the *same* namespace unless the top-level
  `Alertmanager` CR sets `alertmanagerConfigMatcherStrategy: None` (match
  everything) — otherwise `api-alerts`/`pod-health` PrometheusRules and this
  `AlertmanagerConfig` all need to agree on namespace, or routing silently
  stops matching.
- Discord's `discordConfigs` field on `AlertmanagerConfig` requires a modern
  enough Alertmanager (>= v0.25) — confirm the chart's bundled Alertmanager
  version supports it before relying on it; older versions only had generic
  `webhookConfigs`; this repo's `discord-default`/`warnings`/`critical`
  behavior currently depends on native Discord formatting
  (`prometheus-values.yaml:128-161`), so a downgrade path to a webhook +
  reformat may be needed if not.

### 5. Update the deploy scripts

- `monitoring/deploy-prometheus.sh` — replace the `helm upgrade --install
  prom prometheus-community/prometheus ... --set-string
  alertmanager.config.receivers[N]...` calls with `helm upgrade --install
  kube-prom-stack prometheus-community/kube-prometheus-stack -f
  monitoring/kube-prometheus-stack-values.yaml`, and `kubectl create secret
  generic discord-webhooks --from-literal=default-url="$DISCORD_WEBHOOK_URL"`
  in place of the `--set-string` substitution.
- `monitoring/rules/*.yaml` and the `AlertmanagerConfig`/`Secret` manifests
  get applied with `kubectl apply -f monitoring/rules/ -f monitoring/alertmanager-config.yaml`.
- `scripts/run-all.sh` and `scripts/deploy-monitoring.sh` need their calls
  into `deploy-prometheus.sh` updated accordingly; `deploy-monitoring.sh`'s
  separate `helm install grafana grafana/grafana` step can stay as-is if
  `grafana.enabled=false` is kept on the stack chart.

### 6. Verify, then decommission the old release

- `kubectl get prometheusrule,alertmanagerconfig,servicemonitor -n monitoring`
  — confirm all objects are `Accepted`/no errors (`kubectl describe` on any
  CR shows operator-reported validation issues).
- Re-run the same manual test done for the current setup: apply
  `k8s-triage-agent/scenarios/oomkilled.yaml` and `pending.yaml`, confirm
  `PodOOMKilled`/`PodUnschedulable` fire, reach the triage bridge, and that
  `PodNotReady` still shows `state: suppressed` with a nonempty
  `inhibitedBy` in Alertmanager's `/api/v2/alerts`.
- Only after that passes: `helm uninstall prom -n monitoring` (the old
  `prometheus-community/prometheus` release) and remove
  `monitoring/prometheus-values.yaml`.

## Rollback

Until step 6, the old `prom` release and new `kube-prom-stack` release exist
side by side — if the new stack's routing/inhibition doesn't check out,
nothing has to be undone; the old release keeps running unaffected and the
new one can just be `helm uninstall`ed. Do not delete
`prometheus-values.yaml` or run the old release's uninstall until the new
stack passes the same live scenario tests documented in
`k8s-triage-agent/WRITEUP.md`.
