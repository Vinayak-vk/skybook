'use strict';

const { airportsByCode } = require('./airports');

// Flights are not stored anywhere. Every search derives its results from a PRNG
// seeded with the route and date, so the same query always yields the same
// flights and GET /api/flights/:id can rebuild a flight from its id alone.
// That keeps the service stateless and trivially horizontally scalable.

const CRUISE_SPEED_KMH = 800;
const TAXI_AND_CLIMB_MINUTES = 30;
const LONG_HAUL_KM = 4000;

const FIRST_DEPARTURE = 5 * 60; // 05:00
const LAST_DEPARTURE = 23 * 60; // 23:00
const SLOT_MINUTES = 5;

const SHORT_HAUL_AIRCRAFT = ['Airbus A220-300', 'Airbus A320neo', 'Airbus A321neo', 'Boeing 737 MAX 8'];
const LONG_HAUL_AIRCRAFT = ['Airbus A330-900', 'Airbus A350-900', 'Boeing 777-300ER', 'Boeing 787-9'];

const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
// e.g. SB1234-JFK-LAX-20261020
const FLIGHT_ID_PATTERN = /^(SB\d{4})-([A-Z]{3})-([A-Z]{3})-(\d{4})(\d{2})(\d{2})$/;

/** 32-bit FNV-1a: tiny, fast and good enough to spread similar seeds apart. */
function hashString(value) {
  let hash = 0x811c9dc5;
  for (let i = 0; i < value.length; i += 1) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return hash >>> 0;
}

/** mulberry32: a small seeded PRNG returning floats in [0, 1). */
function mulberry32(seed) {
  let state = seed >>> 0;
  return function next() {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Great-circle distance in kilometres. */
function haversineKm(a, b) {
  const earthRadiusKm = 6371;
  const toRad = (deg) => (deg * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const h = Math.sin(dLat / 2) ** 2
    + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * earthRadiusKm * Math.asin(Math.sqrt(h));
}

/** True for real calendar dates in YYYY-MM-DD form (rejects 2026-02-30). */
function isValidDate(value) {
  if (typeof value !== 'string' || !DATE_PATTERN.test(value)) return false;
  const [year, month, day] = value.split('-').map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year
    && date.getUTCMonth() === month - 1
    && date.getUTCDate() === day;
}

/** Minutes after midnight -> "HH:MM", wrapping past midnight for overnight arrivals. */
function formatClock(minutes) {
  const wrapped = ((minutes % 1440) + 1440) % 1440;
  const hh = String(Math.floor(wrapped / 60)).padStart(2, '0');
  const mm = String(wrapped % 60).padStart(2, '0');
  return `${hh}:${mm}`;
}

function pick(rng, items) {
  return items[Math.floor(rng() * items.length)];
}

/** Draws `count` distinct values from `draw()`. */
function distinct(count, draw) {
  const values = new Set();
  while (values.size < count) values.add(draw());
  return [...values];
}

/**
 * Validates and normalises search parameters.
 * Returns { value: { from, to, date } } or { error: message }.
 */
function validateSearch({ from, to, date } = {}) {
  const origin = typeof from === 'string' ? from.trim().toUpperCase() : '';
  const destination = typeof to === 'string' ? to.trim().toUpperCase() : '';
  const day = typeof date === 'string' ? date.trim() : '';

  if (!origin || !destination || !day) {
    return { error: 'Query parameters "from", "to" and "date" are required' };
  }
  for (const code of [origin, destination]) {
    if (!airportsByCode.has(code)) {
      return { error: `Unknown airport code "${code.slice(0, 8)}"` };
    }
  }
  if (origin === destination) {
    return { error: '"from" and "to" must be different airports' };
  }
  if (!isValidDate(day)) {
    return { error: 'Invalid date, expected a calendar date as YYYY-MM-DD' };
  }
  return { value: { from: origin, to: destination, date: day } };
}

/**
 * Generates the 3-6 flights operating on a route for a given day, sorted by
 * departure time. Inputs must already be validated.
 */
function generateFlights(from, to, date) {
  const origin = airportsByCode.get(from);
  const destination = airportsByCode.get(to);
  const rng = mulberry32(hashString(`${from}-${to}-${date}`));

  const distanceKm = haversineKm(origin, destination);
  const blockMinutes = (distanceKm / CRUISE_SPEED_KMH) * 60 + TAXI_AND_CLIMB_MINUTES;
  const aircraftPool = distanceKm > LONG_HAUL_KM ? LONG_HAUL_AIRCRAFT : SHORT_HAUL_AIRCRAFT;
  const baseFare = 59 + distanceKm * 0.09;

  // The order of rng() calls below defines the output; changing it changes
  // every flight id ever issued, so treat it as part of the API contract.
  const count = 3 + Math.floor(rng() * 4);
  const slots = (LAST_DEPARTURE - FIRST_DEPARTURE) / SLOT_MINUTES + 1;
  const departures = distinct(count, () => FIRST_DEPARTURE + Math.floor(rng() * slots) * SLOT_MINUTES)
    .sort((a, b) => a - b);
  const flightNumbers = distinct(count, () => 1000 + Math.floor(rng() * 9000));
  const compactDate = date.replaceAll('-', '');

  return departures.map((departure, index) => {
    // Small per-flight variation (aircraft type, routing) on top of the block time.
    const durationMinutes = Math.round((blockMinutes - 5 + rng() * 20) / SLOT_MINUTES) * SLOT_MINUTES;
    const price = Math.round(baseFare * (0.8 + rng() * 0.6) * 100) / 100;
    const seatsAvailable = Math.floor(rng() * 61);
    const aircraft = pick(rng, aircraftPool);
    const flightNumber = `SB${flightNumbers[index]}`;

    return {
      id: `${flightNumber}-${from}-${to}-${compactDate}`,
      flightNumber,
      from,
      to,
      date,
      departureTime: formatClock(departure),
      arrivalTime: formatClock(departure + durationMinutes),
      durationMinutes,
      price,
      currency: 'USD',
      seatsAvailable,
      aircraft,
    };
  });
}

/** Rebuilds a single flight from its id, or returns null if it does not exist. */
function findFlightById(id) {
  const match = typeof id === 'string' ? FLIGHT_ID_PATTERN.exec(id) : null;
  if (!match) return null;

  const [, flightNumber, from, to, year, month, day] = match;
  const search = validateSearch({ from, to, date: `${year}-${month}-${day}` });
  if (search.error) return null;

  const { value } = search;
  return generateFlights(value.from, value.to, value.date)
    .find((flight) => flight.flightNumber === flightNumber) ?? null;
}

module.exports = {
  findFlightById,
  formatClock,
  generateFlights,
  haversineKm,
  isValidDate,
  validateSearch,
};
