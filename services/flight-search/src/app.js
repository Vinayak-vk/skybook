'use strict';

const express = require('express');

const { airports } = require('./airports');
const config = require('./config');
const { findFlightById, generateFlights, validateSearch } = require('./flights');
const defaultLogger = require('./logger');
const { httpRequestDuration, register } = require('./metrics');

// Probes and scrapes arrive every few seconds; keep them out of the info-level log.
const QUIET_PATHS = new Set(['/healthz', '/readyz', '/metrics']);

/**
 * Records the latency histogram and writes one structured log line per request.
 * The route label is the matched Express route template (e.g. /api/flights/:id),
 * never the raw URL, so label cardinality stays bounded.
 */
function observability(logger) {
  return function observe(req, res, next) {
    const start = process.hrtime.bigint();
    const path = req.path;

    res.on('finish', () => {
      const seconds = Number(process.hrtime.bigint() - start) / 1e9;
      const route = req.route ? `${req.baseUrl}${req.route.path}` : 'unmatched';
      const status = res.statusCode;

      if (path !== '/metrics') {
        httpRequestDuration.observe({ method: req.method, route, status: String(status) }, seconds);
      }

      let level = 'info';
      if (status >= 500) level = 'error';
      else if (QUIET_PATHS.has(path)) level = 'debug';

      logger[level]({
        method: req.method,
        route,
        path,
        status,
        duration_ms: Math.round(seconds * 1e6) / 1e3,
        request_id: req.get('x-request-id'),
      }, 'request completed');
    });

    next();
  };
}

function createApp({ version = config.version, logger = defaultLogger } = {}) {
  const app = express();
  app.disable('x-powered-by');
  app.use(observability(logger));

  app.get('/healthz', (req, res) => {
    res.json({ status: 'ok' });
  });

  // Nothing to warm up or connect to, so ready == alive.
  app.get('/readyz', (req, res) => {
    res.json({ status: 'ready' });
  });

  app.get('/metrics', async (req, res) => {
    res.set('Content-Type', register.contentType);
    res.send(await register.metrics());
  });

  // Literal paths must be registered before /api/flights/:id, otherwise
  // "version", "airports" and "search" would be treated as flight ids.
  app.get('/api/flights/version', (req, res) => {
    res.json({ service: 'flight-search', version });
  });

  app.get('/api/flights/airports', (req, res) => {
    res.json(airports);
  });

  app.get('/api/flights/search', (req, res) => {
    const search = validateSearch(req.query);
    if (search.error) {
      res.status(400).json({ error: search.error });
      return;
    }
    const { from, to, date } = search.value;
    res.json({ from, to, date, flights: generateFlights(from, to, date) });
  });

  app.get('/api/flights/:id', (req, res) => {
    const flight = findFlightById(req.params.id);
    if (!flight) {
      res.status(404).json({ error: 'Flight not found' });
      return;
    }
    res.json(flight);
  });

  app.use((req, res) => {
    res.status(404).json({ error: 'Not found' });
  });

  // Express recognises error handlers by their four-argument signature, so
  // `next` must stay in the parameter list even though it is unused.
  app.use((err, req, res, next) => {
    const status = Number.isInteger(err.status) && err.status >= 400 && err.status < 500 ? err.status : 500;
    if (status === 500) {
      logger.error({ err, path: req.path }, 'unhandled error');
    }
    if (res.headersSent) {
      res.end();
      return;
    }
    res.status(status).json({ error: status === 500 ? 'Internal server error' : err.message });
  });

  return app;
}

module.exports = { createApp };
