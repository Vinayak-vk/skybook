'use strict';

const pino = require('pino');
const config = require('./config');

// One JSON object per line on stdout; the cluster's log agent ships it as-is.
// `level` is rendered as a label ("info") rather than pino's numeric default so
// log queries stay readable and consistent with the other SkyBook services.
const logger = pino({
  level: config.logLevel,
  base: { service: 'flight-search', version: config.version },
  timestamp: pino.stdTimeFunctions.isoTime,
  formatters: {
    level: (label) => ({ level: label }),
  },
});

module.exports = logger;
