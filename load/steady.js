// Steady background traffic at a fixed request rate, for measuring request-level
// availability while something else happens: a chaos scenario, a rolling update
// (O6: 0 failed requests at 100 req/s), a node drain.
//
// Knobs (pass with -e, or as env vars to load/k6.sh):
//   RATE      requests per second                 (default 100)
//   DURATION  how long to run                     (default 5m)
//   WORK_MS   CPU burned per request, ms          (default 5)
//
// constant-arrival-rate keeps the request rate fixed even when the app slows
// down, so a degraded app shows up as failures and latency, not as fewer requests.
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const HOST_HEADER = __ENV.HOST_HEADER || 'autoheal.local';
const RATE = parseInt(__ENV.RATE || '100', 10);
const DURATION = __ENV.DURATION || '5m';
const WORK_MS = __ENV.WORK_MS || '5';

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.max(10, Math.ceil(RATE / 2)),
      maxVUs: RATE * 5,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.005'],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}/work?durationMs=${WORK_MS}`, {
    headers: { Host: HOST_HEADER },
    timeout: '10s',
  });
  check(res, { 'status 200': (r) => r.status === 200 });
}

export function handleSummary(data) {
  const m = data.metrics;
  const v = (name, key) => {
    const x = m[name] && m[name].values[key];
    return x === undefined ? 'NaN' : Number(x).toFixed(key === 'rate' ? 5 : 1);
  };
  const lines = [
    `RESULT requests=${v('http_reqs', 'count')}`,
    `RESULT failed=${v('http_req_failed', 'passes')}`,
    `RESULT failed_rate=${v('http_req_failed', 'rate')}`,
    `RESULT p95_ms=${v('http_req_duration', 'p(95)')}`,
    `RESULT dropped_iterations=${v('dropped_iterations', 'count')}`,
  ];
  return { stdout: lines.join('\n') + '\n' };
}
