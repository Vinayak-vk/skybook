'use strict';

const { describe, test } = require('node:test');
const assert = require('node:assert/strict');

const { airportsByCode } = require('../src/airports');
const {
  findFlightById,
  formatClock,
  generateFlights,
  haversineKm,
  isValidDate,
  validateSearch,
} = require('../src/flights');

const ID_PATTERN = /^SB\d{4}-JFK-LAX-20261020$/;

describe('generateFlights', () => {
  test('returns 3-6 well-formed flights sorted by departure', () => {
    const flights = generateFlights('JFK', 'LAX', '2026-10-20');

    assert.ok(flights.length >= 3 && flights.length <= 6, `got ${flights.length} flights`);
    for (const flight of flights) {
      assert.match(flight.id, ID_PATTERN);
      assert.equal(flight.id.startsWith(`${flight.flightNumber}-`), true);
      assert.match(flight.departureTime, /^\d{2}:\d{2}$/);
      assert.match(flight.arrivalTime, /^\d{2}:\d{2}$/);
      assert.equal(flight.currency, 'USD');
      assert.ok(Number.isInteger(flight.seatsAvailable));
      assert.ok(flight.seatsAvailable >= 0 && flight.seatsAvailable <= 60);
      assert.equal(Math.round(flight.price * 100) / 100, flight.price, 'price has at most 2 decimals');
    }

    const departures = flights.map((flight) => flight.departureTime);
    assert.deepEqual(departures, [...departures].sort());
    assert.equal(new Set(flights.map((flight) => flight.id)).size, flights.length, 'ids are unique');
  });

  test('is deterministic for the same route and date', () => {
    assert.deepEqual(generateFlights('LHR', 'SIN', '2026-12-24'), generateFlights('LHR', 'SIN', '2026-12-24'));
  });

  test('differs between dates', () => {
    assert.notDeepEqual(generateFlights('JFK', 'LAX', '2026-10-20'), generateFlights('JFK', 'LAX', '2026-10-21'));
  });

  test('derives duration from distance and scales price with it', () => {
    const [short] = generateFlights('BOS', 'JFK', '2026-10-20');
    const [long] = generateFlights('LHR', 'SIN', '2026-10-20');

    // ~300 km -> ~52 min block time; ~10,900 km -> ~14 h.
    assert.ok(short.durationMinutes >= 45 && short.durationMinutes <= 75, `short ${short.durationMinutes}`);
    assert.ok(long.durationMinutes >= 820 && long.durationMinutes <= 860, `long ${long.durationMinutes}`);
    assert.ok(long.price > short.price * 3);
  });
});

describe('findFlightById', () => {
  test('rebuilds exactly the flight returned by a search', () => {
    for (const flight of generateFlights('ATL', 'CDG', '2027-01-15')) {
      assert.deepEqual(findFlightById(flight.id), flight);
    }
  });

  test('returns null for unknown or malformed ids', () => {
    assert.equal(findFlightById('SB0000-JFK-LAX-20261020'), null);
    assert.equal(findFlightById('SB1234-XXX-LAX-20261020'), null);
    assert.equal(findFlightById('SB1234-JFK-JFK-20261020'), null);
    assert.equal(findFlightById('SB1234-JFK-LAX-20260230'), null);
    assert.equal(findFlightById('not-a-flight'), null);
    assert.equal(findFlightById(undefined), null);
  });
});

describe('validateSearch', () => {
  test('normalises valid input', () => {
    assert.deepEqual(validateSearch({ from: ' jfk ', to: 'lax', date: '2026-10-20' }), {
      value: { from: 'JFK', to: 'LAX', date: '2026-10-20' },
    });
  });

  test('rejects missing, unknown, identical and invalid values', () => {
    assert.ok(validateSearch({ from: 'JFK', to: 'LAX' }).error);
    assert.ok(validateSearch({ from: 'XXX', to: 'LAX', date: '2026-10-20' }).error);
    assert.ok(validateSearch({ from: 'JFK', to: 'JFK', date: '2026-10-20' }).error);
    assert.ok(validateSearch({ from: 'JFK', to: 'LAX', date: '20-10-2026' }).error);
    assert.ok(validateSearch({ from: ['JFK', 'BOS'], to: 'LAX', date: '2026-10-20' }).error);
  });
});

describe('helpers', () => {
  test('isValidDate checks real calendar dates', () => {
    assert.equal(isValidDate('2028-02-29'), true);
    assert.equal(isValidDate('2026-02-29'), false);
    assert.equal(isValidDate('2026-13-01'), false);
    assert.equal(isValidDate('2026-1-1'), false);
  });

  test('formatClock wraps past midnight', () => {
    assert.equal(formatClock(0), '00:00');
    assert.equal(formatClock(23 * 60 + 55), '23:55');
    assert.equal(formatClock(24 * 60 + 65), '01:05');
  });

  test('haversineKm matches the known JFK-LAX distance', () => {
    const km = haversineKm(airportsByCode.get('JFK'), airportsByCode.get('LAX'));
    assert.ok(Math.abs(km - 3983) < 15, `got ${km}`);
  });
});
