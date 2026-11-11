const express = require("express");
const client = require("prom-client");

const app = express();
const port = process.env.PORT || 3000;
const env = process.env.ENV || "development";
const version = process.env.APP_VERSION || "v2";

// Fail fast on bad config instead of running half-broken. A typo'd MODE in
// the ConfigMap shows up as a CrashLoopBackOff with a clear log line, which
// is also what the k8s-triage-agent "configerror" scenario relies on.
const VALID_MODES = ["production", "development"];
const mode = process.env.MODE || "development";
if (!VALID_MODES.includes(mode)) {
  console.error(
    `FATAL: invalid MODE=${JSON.stringify(mode)}; expected one of ${VALID_MODES.join(", ")}`
  );
  process.exit(1);
}

// Prometheus Registry
const register = new client.Registry();
client.collectDefaultMetrics({ register });

// RED metrics
const requestCounter = new client.Counter({
  name: "http_requests_total",
  help: "Total number of HTTP requests",
  labelNames: ["route", "method", "status"],
});

const errorCounter = new client.Counter({
  name: "http_errors_total",
  help: "Total number of HTTP 5xx responses",
  labelNames: ["route", "method", "status"],
});

const latencyHistogram = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "Request duration in seconds",
  labelNames: ["route", "method", "status"],
  buckets: [0.1, 0.3, 1.0, 3.0, 5.0],
});

register.registerMetric(requestCounter);
register.registerMetric(errorCounter);
register.registerMetric(latencyHistogram);

// Probe and scrape traffic would otherwise dominate the request count and
// dilute the error ratio that alerts and canary analysis are based on.
const UNTRACKED_PATHS = new Set(["/health", "/ready", "/metrics"]);

// Middleware for RED metrics. This is the ONLY place metrics are recorded,
// so every response is counted exactly once.
app.use((req, res, next) => {
  if (UNTRACKED_PATHS.has(req.path)) return next();

  const start = process.hrtime.bigint();

  res.on("finish", () => {
    // Use the matched route pattern, never the raw path: raw paths from
    // 404 scans would create an unbounded number of label values.
    const route = req.route?.path || "unmatched";
    const labels = { route, method: req.method, status: res.statusCode };

    requestCounter.inc(labels);
    if (res.statusCode >= 500) errorCounter.inc(labels);

    const seconds = Number(process.hrtime.bigint() - start) / 1e9;
    latencyHistogram.observe(labels, seconds);
  });

  next();
});

// Readiness goes false once shutdown starts, so the Service stops sending
// new traffic before the process exits.
let shuttingDown = false;

app.get("/", (req, res) => {
  res.send("Hello from API! Environment: " + env);
});

app.get("/health", (req, res) => res.send("ok"));
app.get("/ready", (req, res) => {
  if (shuttingDown) return res.status(503).send("shutting down");
  res.send("ready");
});
app.get("/version", (req, res) => res.send(version));

// Simulated error endpoint — counted by the middleware like any other 5xx.
app.get("/error", (req, res) => {
  res.status(500).send("Simulated API error");
});

// Prometheus metrics endpoint
app.get("/metrics", async (req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});

// Global error handler. Counted by the middleware via the 500 status; the
// error details go to the log, not to the client.
app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).send("Internal server error");
});

const server = app.listen(port, () => console.log(`API listening on ${port}`));

// Graceful shutdown on SIGTERM (sent by Kubernetes when a pod is deleted,
// e.g. during a rollout or scale-down): fail readiness, give the endpoints
// controller a few seconds to take this pod out of the Service, then finish
// in-flight requests and exit. Stays well inside the pod's
// terminationGracePeriodSeconds (30s).
const DRAIN_DELAY_MS = Number(process.env.SHUTDOWN_DRAIN_MS || 5000);
process.on("SIGTERM", () => {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`SIGTERM received; draining for ${DRAIN_DELAY_MS}ms`);
  setTimeout(() => {
    server.close(() => process.exit(0));
    // Don't hang forever on keep-alive connections.
    setTimeout(() => process.exit(0), 10000).unref();
  }, DRAIN_DELAY_MS);
});
