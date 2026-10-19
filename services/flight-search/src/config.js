'use strict';

// All runtime configuration comes from the environment (12-factor), read once at startup.
const port = Number.parseInt(process.env.PORT ?? '', 10);

module.exports = Object.freeze({
  port: Number.isInteger(port) && port > 0 ? port : 3000,
  version: process.env.APP_VERSION || 'dev',
  logLevel: process.env.LOG_LEVEL || 'info',
});
