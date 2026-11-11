// Smoke tests: start the real app as a child process and hit it over HTTP.
// Run with `npm test` (Node's built-in test runner, no extra dependencies).
const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const path = require("node:path");

const APP = path.join(__dirname, "..", "src", "index.js");
const PORT = 3917;
const BASE = `http://127.0.0.1:${PORT}`;

function startApp(env = {}) {
  return spawn(process.execPath, [APP], {
    env: { ...process.env, PORT: String(PORT), MODE: "production", ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
}

async function waitForReady() {
  for (let i = 0; i < 50; i++) {
    try {
      const res = await fetch(`${BASE}/ready`);
      if (res.ok) return;
    } catch {
      // not listening yet
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("app did not become ready");
}

function metricValue(body, name, labels) {
  const line = body
    .split("\n")
    .find((l) => l.startsWith(name + "{") && labels.every((lb) => l.includes(lb)));
  return line ? Number(line.trim().split(" ").pop()) : 0;
}

let app;
before(async () => {
  app = startApp();
  await waitForReady();
});
after(() => app.kill("SIGKILL"));

test("health, readiness and version respond", async () => {
  assert.equal((await fetch(`${BASE}/health`)).status, 200);
  assert.equal((await fetch(`${BASE}/ready`)).status, 200);
  assert.equal((await fetch(`${BASE}/version`)).status, 200);
});

test("/error is counted exactly once as a 5xx", async () => {
  const labels = ['route="/error"', 'status="500"'];
  const before = metricValue(await (await fetch(`${BASE}/metrics`)).text(), "http_errors_total", labels);
  assert.equal((await fetch(`${BASE}/error`)).status, 500);
  const after = metricValue(await (await fetch(`${BASE}/metrics`)).text(), "http_errors_total", labels);
  assert.equal(after - before, 1);
});

test("unknown paths share one 'unmatched' label (bounded cardinality)", async () => {
  await fetch(`${BASE}/does-not-exist-1`);
  await fetch(`${BASE}/does-not-exist-2`);
  const body = await (await fetch(`${BASE}/metrics`)).text();
  assert.ok(body.includes('route="unmatched"'));
  assert.ok(!body.includes("does-not-exist"));
});

test("probe and scrape endpoints are not counted as traffic", async () => {
  const body = await (await fetch(`${BASE}/metrics`)).text();
  for (const p of ["/health", "/ready", "/metrics"]) {
    assert.ok(!body.includes(`route="${p}"`), `${p} should not be tracked`);
  }
});

test("invalid MODE exits non-zero at startup", async () => {
  const bad = spawn(process.execPath, [APP], {
    env: { ...process.env, PORT: String(PORT + 1), MODE: "prod" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const code = await new Promise((resolve) => bad.on("exit", resolve));
  assert.equal(code, 1);
});
