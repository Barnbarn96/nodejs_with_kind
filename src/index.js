const express = require("express");
const client = require("prom-client");

const app = express();
const port = process.env.PORT || 3000;
const env  = process.env.ENV || "development";

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
  help: "Total number of HTTP errors",
  labelNames: ["route", "method", "status"],
});

const latencyHistogram = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "Request duration in seconds",
  labelNames: ["route", "method", "status"],
  buckets: [0.1, 0.3, 1.0, 3.0, 5.0]
});

register.registerMetric(requestCounter);
register.registerMetric(errorCounter);
register.registerMetric(latencyHistogram);

// Middleware for RED metrics
app.use(async (req, res, next) => {
  const start = process.hrtime();

  res.on("finish", () => {
    const route = req.route?.path || req.path || "unknown";
    const method = req.method;
    const status = res.statusCode;

    requestCounter.inc({ route, method, status });

    if (status >= 500) {
      errorCounter.inc({ route, method, status });
    }

    const diff = process.hrtime(start);
    const duration = diff[0] + diff[1] / 1e9;

    latencyHistogram.observe({ route, method, status }, duration);
  });

  next();
});

// Normal routes
app.get("/", (req, res) => {
  res.send("Hello from API! Environment: " + env);
});

app.get("/health", (req, res) => res.send("ok"));
app.get("/ready", (req, res) => res.send("ready"));

// Simulated error endpoint
app.get('/error', (req, res) => {
    errorCounter.inc({ route: '/error' });
    res.status(500).send('Simulated API error');
});

// Global error handler (also tracked)
app.use((err, req, res, next) => {
  errorCounter.inc({
    route: req.route?.path || req.path,
    method: req.method,
    status: 500
  });

  res.status(500).send("Something broke: " + err.message);
});

// Prometheus metrics endpoint
app.get("/metrics", async (req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});

app.listen(port, () => console.log(`API listening on ${port}`));
