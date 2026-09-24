// T5 traffic spike: ramps virtual users on the CPU-heavy /work endpoint to push
// average CPU past the HPA target, holds at peak while the HPA scales out, then
// stops (which is where T6's scale-in clock starts).
//
// Knobs (pass with -e, or as env vars to load/k6.sh):
//   PEAK_VUS  peak virtual users               (default 500)
//   RAMP      time to ramp from 10 to PEAK_VUS (default 5m)
//   HOLD      time held at PEAK_VUS            (default 3m)
//   WORK_MS   CPU burned per request, ms       (default 10)
//   THINK_S   pause between a VU's requests, s (default 3)
//
// Offered load is roughly PEAK_VUS / THINK_S req/s. With the defaults that is
// ~165 req/s x 10ms = ~1.7 cores of work: far beyond 2 pods (2 x 300m limit),
// but within 8 pods (2.4 cores), so p95 latency should recover once scaled out.
import http from 'k6/http';
import { check, sleep } from 'k6';
import exec from 'k6/execution';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const HOST_HEADER = __ENV.HOST_HEADER || 'autoheal.local';
const PEAK_VUS = parseInt(__ENV.PEAK_VUS || '500', 10);
const RAMP = __ENV.RAMP || '5m';
const HOLD = __ENV.HOLD || '3m';
const WORK_MS = __ENV.WORK_MS || '10';
const THINK_S = parseFloat(__ENV.THINK_S || '3');

function seconds(d) {
  const m = /^(\d+)(s|m)$/.exec(d);
  if (!m) throw new Error(`unsupported duration "${d}", use e.g. 90s or 5m`);
  return parseInt(m[1], 10) * (m[2] === 'm' ? 60 : 1);
}

// Requests in the second half of the hold are tagged phase=recovered: by then the
// HPA should be at max, so their p95 shows whether scaling out actually helped.
const RECOVERED_AFTER_MS = (seconds(RAMP) + seconds(HOLD) / 2) * 1000;

export const options = {
  stages: [
    { duration: RAMP, target: PEAK_VUS },
    { duration: HOLD, target: PEAK_VUS },
    { duration: '30s', target: 0 },
  ],
  startVUs: 10,
  // Thresholds are also what makes k6 compute the tagged sub-metric below.
  thresholds: {
    http_req_failed: ['rate<0.005'],
    'http_req_duration{phase:recovered}': ['p(95)<500'],
  },
};

export default function () {
  const phase =
    exec.instance.currentTestRunDuration >= RECOVERED_AFTER_MS ? 'recovered' : 'scaling';
  const res = http.get(`${BASE_URL}/work?durationMs=${WORK_MS}`, {
    headers: { Host: HOST_HEADER },
    tags: { phase },
    timeout: '30s',
  });
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(THINK_S);
}

export function handleSummary(data) {
  const m = data.metrics;
  const v = (name, key) => {
    const x = m[name] && m[name].values[key];
    return x === undefined ? 'NaN' : Number(x).toFixed(key === 'rate' ? 5 : 1);
  };
  const lines = [
    `RESULT requests=${v('http_reqs', 'count')}`,
    `RESULT failed_rate=${v('http_req_failed', 'rate')}`,
    `RESULT p95_ms=${v('http_req_duration', 'p(95)')}`,
    `RESULT p95_recovered_ms=${v('http_req_duration{phase:recovered}', 'p(95)')}`,
    `RESULT max_vus=${v('vus_max', 'max')}`,
  ];
  return { stdout: lines.join('\n') + '\n' };
}
