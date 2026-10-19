'use strict';

// Static reference data. Coordinates are only used to derive distances, so
// four decimal places (~10 m) is far more precision than needed.
const airports = Object.freeze([
  { code: 'ATL', city: 'Atlanta', country: 'United States', lat: 33.6407, lon: -84.4277 },
  { code: 'JFK', city: 'New York', country: 'United States', lat: 40.6413, lon: -73.7781 },
  { code: 'LAX', city: 'Los Angeles', country: 'United States', lat: 33.9416, lon: -118.4085 },
  { code: 'SEA', city: 'Seattle', country: 'United States', lat: 47.4502, lon: -122.3088 },
  { code: 'ORD', city: 'Chicago', country: 'United States', lat: 41.9742, lon: -87.9073 },
  { code: 'DFW', city: 'Dallas', country: 'United States', lat: 32.8998, lon: -97.0403 },
  { code: 'BOS', city: 'Boston', country: 'United States', lat: 42.3656, lon: -71.0096 },
  { code: 'SFO', city: 'San Francisco', country: 'United States', lat: 37.6213, lon: -122.379 },
  { code: 'MIA', city: 'Miami', country: 'United States', lat: 25.7959, lon: -80.287 },
  { code: 'DEN', city: 'Denver', country: 'United States', lat: 39.8561, lon: -104.6737 },
  { code: 'LHR', city: 'London', country: 'United Kingdom', lat: 51.47, lon: -0.4543 },
  { code: 'CDG', city: 'Paris', country: 'France', lat: 49.0097, lon: 2.5479 },
  { code: 'DXB', city: 'Dubai', country: 'United Arab Emirates', lat: 25.2532, lon: 55.3657 },
  { code: 'SIN', city: 'Singapore', country: 'Singapore', lat: 1.3644, lon: 103.9915 },
  { code: 'DEL', city: 'Delhi', country: 'India', lat: 28.5562, lon: 77.1 },
  { code: 'BOM', city: 'Mumbai', country: 'India', lat: 19.0896, lon: 72.8656 },
].map((airport) => Object.freeze(airport)));

const airportsByCode = new Map(airports.map((airport) => [airport.code, airport]));

module.exports = { airports, airportsByCode };
