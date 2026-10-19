'use strict';

const { createApp } = require('./app');
const config = require('./config');
const logger = require('./logger');

const SHUTDOWN_TIMEOUT_MS = 10_000;

const app = createApp();

const server = app.listen(config.port, (err) => {
  if (err) {
    logger.fatal({ err }, 'failed to start');
    process.exit(1);
  }
  logger.info({ port: config.port }, 'flight-search listening');
});

// Keep idle connections open longer than typical proxy/load-balancer idle
// timeouts so the proxy never reuses a socket Node has just closed (-> 502s).
server.keepAliveTimeout = 65_000;
server.headersTimeout = 66_000;

let shuttingDown = false;

// Kubernetes sends SIGTERM and waits terminationGracePeriodSeconds before
// SIGKILL: stop accepting connections, let in-flight requests finish, then exit.
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.info({ signal }, 'shutting down');

  server.close((err) => {
    if (err) {
      logger.error({ err }, 'error while closing server');
      process.exit(1);
    }
    logger.info('shutdown complete');
    process.exit(0);
  });
  server.closeIdleConnections();

  setTimeout(() => {
    logger.warn('in-flight requests did not finish in time, forcing exit');
    process.exit(1);
  }, SHUTDOWN_TIMEOUT_MS).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
