const express = require('express');
const {
  register,
  httpRequestDuration,
  crashTriggeredTotal,
  hangTriggeredTotal,
} = require('./metrics');

const PORT = parseInt(process.env.PORT || '3000', 10);
const STARTUP_DELAY_MS = parseInt(process.env.STARTUP_DELAY_MS || '0', 10);
const MAX_HANG_MS = parseInt(process.env.MAX_HANG_MS || '30000', 10);
const MAX_WORK_MS = parseInt(process.env.MAX_WORK_MS || '5000', 10);
const MAX_UNREADY_SECONDS = parseInt(process.env.MAX_UNREADY_SECONDS || '300', 10);

const app = express();
app.use(express.json());

let startedUp = STARTUP_DELAY_MS === 0;
if (!startedUp) {
  setTimeout(() => {
    startedUp = true;
  }, STARTUP_DELAY_MS);
}

let unreadyUntil = 0;

app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer({ method: req.method, route: req.path });
  res.on('finish', () => end({ status_code: res.statusCode }));
  next();
});

// Startup probe target: only succeeds once initial boot delay has elapsed.
app.get('/startupz', (req, res) => {
  if (!startedUp) return res.status(503).json({ status: 'starting' });
  res.status(200).json({ status: 'started' });
});

// Liveness probe target. Kept deliberately cheap so that only a genuinely
// blocked event loop (see /hang) causes probe failures.
app.get('/healthz', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

// Readiness probe target. Reflects both startup state and any chaos-induced
// "not ready" window triggered via /chaos/unready.
app.get('/ready', (req, res) => {
  if (!startedUp) return res.status(503).json({ status: 'starting' });
  if (Date.now() < unreadyUntil) return res.status(503).json({ status: 'unready' });
  res.status(200).json({ status: 'ready' });
});

// Chaos helper for T4: force /ready to return 503 for N seconds.
app.post('/chaos/unready', (req, res) => {
  const seconds = Math.min(
    parseInt(req.body?.seconds ?? req.query.seconds ?? '60', 10),
    MAX_UNREADY_SECONDS
  );
  unreadyUntil = Date.now() + seconds * 1000;
  res.status(200).json({ status: 'unready', forSeconds: seconds });
});

// CPU-heavy endpoint for load testing (T5/T6). Burns CPU synchronously for
// durationMs, which is what the HPA's CPU metric picks up.
app.get('/work', (req, res) => {
  const durationMs = Math.min(
    parseInt(req.query.durationMs ?? '200', 10),
    MAX_WORK_MS
  );
  const end = Date.now() + durationMs;
  let x = 0;
  while (Date.now() < end) {
    x += Math.sqrt(x + 1);
  }
  res.status(200).json({ status: 'done', durationMs });
});

// Blocks the Node event loop synchronously to simulate a hung app (T3).
// Because this blocks the whole process, in-flight liveness probe requests
// will also stall until the loop ends, causing the liveness probe to fail.
app.get('/hang', (req, res) => {
  const durationMs = Math.min(
    parseInt(req.query.durationMs ?? '15000', 10),
    MAX_HANG_MS
  );
  hangTriggeredTotal.inc();
  const end = Date.now() + durationMs;
  while (Date.now() < end) {
    // busy-wait, intentionally blocking
  }
  res.status(200).json({ status: 'unhung', durationMs });
});

// Simulates a process crash (T2). Responds first, then exits on next tick
// so the client sees the 200 before the container dies.
app.post('/crash', (req, res) => {
  crashTriggeredTotal.inc();
  res.status(200).json({ status: 'crashing' });
  setImmediate(() => process.exit(1));
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

if (require.main === module) {
  const server = app.listen(PORT, () => {
    // eslint-disable-next-line no-console
    console.log(`autoheal-api listening on port ${PORT}`);
  });

  const shutdown = (signal) => {
    // eslint-disable-next-line no-console
    console.log(`received ${signal}, shutting down`);
    server.close(() => process.exit(0));
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

module.exports = app;
