'use strict';

const client = require('prom-client');

// Process-wide registry: CPU, memory, event-loop lag, GC, etc.
const register = client.register;
client.collectDefaultMetrics({ register });

// Same name, labels and buckets as booking-api so dashboards and SLO rules can
// aggregate across services. Buckets cover 1 ms .. 5 s, which is where an API
// like this one lives; anything slower is an outage, not a latency tail.
const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request latency in seconds.',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});

module.exports = { register, httpRequestDuration };
