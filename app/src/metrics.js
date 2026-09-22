const client = require('prom-client');

const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.01, 0.05, 0.1, 0.3, 0.5, 1, 2, 5],
});

const crashTriggeredTotal = new client.Counter({
  name: 'app_crash_triggered_total',
  help: 'Number of times the /crash endpoint was called',
});

const hangTriggeredTotal = new client.Counter({
  name: 'app_hang_triggered_total',
  help: 'Number of times the /hang endpoint was called',
});

register.registerMetric(httpRequestDuration);
register.registerMetric(crashTriggeredTotal);
register.registerMetric(hangTriggeredTotal);

module.exports = {
  register,
  httpRequestDuration,
  crashTriggeredTotal,
  hangTriggeredTotal,
};
