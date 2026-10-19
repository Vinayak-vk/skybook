'use strict';

const { after, before, describe, test } = require('node:test');
const assert = require('node:assert/strict');

// Must be set before the logger module is loaded.
process.env.LOG_LEVEL = 'silent';

const { createApp } = require('../src/app');

let server;
let baseUrl;

before(async () => {
  const app = createApp({ version: '1.2.3-test' });
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});

async function get(path) {
  const response = await fetch(`${baseUrl}${path}`);
  const contentType = response.headers.get('content-type') ?? '';
  const body = contentType.includes('application/json') ? await response.json() : await response.text();
  return { status: response.status, contentType, body };
}

describe('probes and version', () => {
  test('GET /healthz', async () => {
    const { status, body } = await get('/healthz');
    assert.equal(status, 200);
    assert.deepEqual(body, { status: 'ok' });
  });

  test('GET /readyz', async () => {
    const { status, body } = await get('/readyz');
    assert.equal(status, 200);
    assert.deepEqual(body, { status: 'ready' });
  });

  test('GET /api/flights/version is not shadowed by /:id', async () => {
    const { status, body } = await get('/api/flights/version');
    assert.equal(status, 200);
    assert.deepEqual(body, { service: 'flight-search', version: '1.2.3-test' });
  });
});

describe('GET /api/flights/airports', () => {
  test('lists airports with coordinates', async () => {
    const { status, body } = await get('/api/flights/airports');
    assert.equal(status, 200);
    assert.equal(body.length, 16);
    const jfk = body.find((airport) => airport.code === 'JFK');
    assert.deepEqual(Object.keys(jfk).sort(), ['city', 'code', 'country', 'lat', 'lon']);
    assert.equal(jfk.city, 'New York');
  });
});

describe('GET /api/flights/search', () => {
  test('returns flights for a valid route', async () => {
    const { status, body } = await get('/api/flights/search?from=jfk&to=LAX&date=2026-10-20');
    assert.equal(status, 200);
    assert.equal(body.from, 'JFK');
    assert.equal(body.to, 'LAX');
    assert.equal(body.date, '2026-10-20');
    assert.ok(body.flights.length >= 3 && body.flights.length <= 6);
    assert.deepEqual(Object.keys(body.flights[0]).sort(), [
      'aircraft', 'arrivalTime', 'currency', 'date', 'departureTime', 'durationMinutes',
      'flightNumber', 'from', 'id', 'price', 'seatsAvailable', 'to',
    ]);
  });

  test('returns identical results for repeated searches', async () => {
    const first = await get('/api/flights/search?from=SEA&to=MIA&date=2026-11-02');
    const second = await get('/api/flights/search?from=SEA&to=MIA&date=2026-11-02');
    assert.deepEqual(first.body, second.body);
  });

  const invalid = {
    'unknown airport': '?from=XXX&to=LAX&date=2026-10-20',
    'same origin and destination': '?from=JFK&to=JFK&date=2026-10-20',
    'impossible date': '?from=JFK&to=LAX&date=2026-02-30',
    'malformed date': '?from=JFK&to=LAX&date=tomorrow',
    'missing parameters': '?from=JFK',
  };
  for (const [name, query] of Object.entries(invalid)) {
    test(`400 for ${name}`, async () => {
      const { status, body } = await get(`/api/flights/search${query}`);
      assert.equal(status, 400);
      assert.equal(typeof body.error, 'string');
    });
  }
});

describe('GET /api/flights/:id', () => {
  test('returns the same flight the search returned', async () => {
    const search = await get('/api/flights/search?from=DXB&to=BOM&date=2026-10-25');
    for (const flight of search.body.flights) {
      const { status, body } = await get(`/api/flights/${flight.id}`);
      assert.equal(status, 200);
      assert.deepEqual(body, flight);
    }
  });

  test('404 for an unknown flight', async () => {
    const { status, body } = await get('/api/flights/SB0000-JFK-LAX-20261020');
    assert.equal(status, 404);
    assert.equal(typeof body.error, 'string');
  });

  test('404 for a malformed id', async () => {
    const { status } = await get('/api/flights/nope');
    assert.equal(status, 404);
  });
});

describe('GET /metrics', () => {
  test('exposes default and HTTP metrics with route templates', async () => {
    await get('/api/flights/SB0000-JFK-LAX-20261020');
    await get('/does-not-exist');
    await get('/metrics');

    const { status, contentType, body } = await get('/metrics');
    assert.equal(status, 200);
    assert.match(contentType, /^text\/plain/);
    assert.match(body, /process_cpu_user_seconds_total/);
    assert.match(body, /# TYPE http_request_duration_seconds histogram/);
    assert.match(body, /http_request_duration_seconds_count\{[^}]*route="\/api\/flights\/:id"[^}]*status="404"/);
    assert.match(body, /http_request_duration_seconds_count\{[^}]*route="\/api\/flights\/search"/);
    assert.match(body, /http_request_duration_seconds_count\{[^}]*route="unmatched"/);
    assert.doesNotMatch(body, /route="\/metrics"/);
  });
});
