// SkyBook frontend: plain ES modules, no framework, no build step.
// All dynamic text goes through textContent, never innerHTML, and the page
// runs under a strict CSP (no inline script or style).

const API = {
  airports: '/api/flights/airports',
  search: '/api/flights/search',
  bookings: '/api/bookings',
};

const REFERENCE_PATTERN = /^[A-Z0-9]{6}$/;
const FLIGHT_ID_PATTERN = /^(SB\d{4})-([A-Z]{3})-([A-Z]{3})-(\d{4})(\d{2})(\d{2})$/;
const MAX_SEATS_PER_BOOKING = 9;
const LOW_SEATS_THRESHOLD = 5;

const $ = (selector, root = document) => root.querySelector(selector);

const airportsByCode = new Map();
let selectedFlight = null;

// --- HTTP ---------------------------------------------------------------------

class ApiError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
  }
}

/** Turns FastAPI / Express error bodies into one readable sentence. */
function errorMessage(body, status) {
  if (body && typeof body.error === 'string') return body.error;
  if (body && typeof body.detail === 'string') return body.detail;
  if (body && Array.isArray(body.detail)) {
    return body.detail
      .map((issue) => {
        const field = Array.isArray(issue.loc) ? issue.loc[issue.loc.length - 1] : '';
        const message = String(issue.msg || 'is invalid').replace(/^Value error, /, '');
        return field ? `${String(field).replace(/_/g, ' ')}: ${message}` : message;
      })
      .join('; ');
  }
  if (status === 502 || status === 503 || status === 504) {
    return 'The service is temporarily unavailable. Please try again in a moment.';
  }
  return `Something went wrong (HTTP ${status}).`;
}

async function fetchJSON(url, { method = 'GET', body, timeout = 10000 } = {}) {
  const headers = { Accept: 'application/json' };
  if (body !== undefined) headers['Content-Type'] = 'application/json';

  let response;
  try {
    response = await fetch(url, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(timeout),
    });
  } catch (err) {
    const timedOut = err && err.name === 'TimeoutError';
    throw new ApiError(
      timedOut ? 'The request timed out. Please try again.' : 'Network error. Check your connection and try again.',
      0,
    );
  }

  const data = await response.json().catch(() => null);
  if (!response.ok) throw new ApiError(errorMessage(data, response.status), response.status);
  return data;
}

// --- formatting ---------------------------------------------------------------

const moneyFormatters = new Map();
function formatMoney(amount, currency = 'USD') {
  if (!moneyFormatters.has(currency)) {
    moneyFormatters.set(currency, new Intl.NumberFormat(undefined, { style: 'currency', currency }));
  }
  return moneyFormatters.get(currency).format(amount);
}

function formatDuration(minutes) {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return h ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`;
}

/** "2026-10-20" -> "Tue, Oct 20, 2026" without time-zone surprises. */
function formatDate(isoDate, options = { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' }) {
  const [y, m, d] = isoDate.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, options);
}

function formatDateTime(iso) {
  const date = new Date(iso);
  return Number.isNaN(date.getTime())
    ? iso
    : date.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

function toISODate(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function minutesOf(clock) {
  const [h, m] = clock.split(':').map(Number);
  return h * 60 + m;
}

/** Days between departure and arrival (0 = same day). Times carry no zone. */
function arrivalDayOffset(flight) {
  return Math.floor((minutesOf(flight.departureTime) + flight.durationMinutes) / 1440);
}

function cityLabel(code) {
  const airport = airportsByCode.get(code);
  return airport ? `${airport.city} (${code})` : code;
}

/** "ada.lovelace@example.com" -> "a***@example.com": references are shareable, emails less so. */
function maskEmail(email) {
  const [user, domain] = String(email).split('@');
  if (!domain) return email;
  return `${user.slice(0, 1)}***@${domain}`;
}

// --- small DOM helpers -------------------------------------------------------

function el(tag, { className, text } = {}, children = []) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  for (const child of children) node.append(child);
  return node;
}

function detailList(entries) {
  return el(
    'dl',
    { className: 'booking-details' },
    entries.map(([term, value]) => el('div', {}, [el('dt', { text: term }), el('dd', { text: value })])),
  );
}

function showAlert(container, message, { retry } = {}) {
  container.replaceChildren(el('span', { text: message }));
  if (retry) {
    const button = el('button', { className: 'btn btn-ghost btn-small', text: 'Try again' });
    button.type = 'button';
    button.addEventListener('click', retry);
    container.append(button);
  }
  container.hidden = false;
}

function setLoading(button, loading, label) {
  button.disabled = loading;
  button.classList.toggle('is-loading', loading);
  button.setAttribute('aria-busy', String(loading));
  if (label) {
    const span = $('span', button);
    (span || button).textContent = label;
  }
}

// --- airports -----------------------------------------------------------------

async function loadAirports() {
  const fromSelect = $('#from');
  const toSelect = $('#to');
  const errorBox = $('#search-error');
  errorBox.hidden = true;

  try {
    const airports = await fetchJSON(API.airports);
    airports.sort((a, b) => a.city.localeCompare(b.city));
    airportsByCode.clear();
    for (const airport of airports) airportsByCode.set(airport.code, airport);

    for (const select of [fromSelect, toSelect]) {
      select.replaceChildren(
        ...airports.map((airport) => {
          const option = el('option', { text: `${airport.city} (${airport.code}) · ${airport.country}` });
          option.value = airport.code;
          return option;
        }),
      );
      select.disabled = false;
    }
    fromSelect.value = airportsByCode.has('JFK') ? 'JFK' : airports[0].code;
    toSelect.value = airportsByCode.has('LAX') ? 'LAX' : airports[1].code;
    $('#search-submit').disabled = false;
  } catch (err) {
    for (const select of [fromSelect, toSelect]) {
      select.replaceChildren(el('option', { text: 'Unavailable' }));
    }
    showAlert(errorBox, `Couldn't load airports. ${err.message}`, { retry: loadAirports });
  }
}

// --- search -------------------------------------------------------------------

function renderSkeletons(list, count = 3) {
  const template = $('#skeleton-template');
  list.replaceChildren(...Array.from({ length: count }, () => template.content.cloneNode(true)));
}

function renderFlight(flight) {
  const fragment = $('#flight-card-template').content.cloneNode(true);
  const field = (name) => $(`[data-field="${name}"]`, fragment);

  field('departure').textContent = flight.departureTime;
  field('arrival').textContent = flight.arrivalTime;
  field('from').textContent = flight.from;
  field('to').textContent = flight.to;
  field('duration').textContent = formatDuration(flight.durationMinutes);
  field('number').textContent = flight.flightNumber;
  field('aircraft').textContent = flight.aircraft;
  field('price').textContent = formatMoney(flight.price, flight.currency);

  const offset = arrivalDayOffset(flight);
  if (offset > 0) {
    const sup = field('next-day');
    sup.textContent = `+${offset}`;
    sup.title = offset === 1 ? 'Arrives the next day' : `Arrives ${offset} days later`;
    sup.hidden = false;
  }

  const seats = field('seats');
  const button = $('[data-action="book"]', fragment);
  if (flight.seatsAvailable === 0) {
    seats.textContent = 'Sold out';
    seats.classList.add('is-none');
    button.disabled = true;
    button.textContent = 'Sold out';
  } else {
    const plural = flight.seatsAvailable === 1 ? 'seat' : 'seats';
    seats.textContent = flight.seatsAvailable <= LOW_SEATS_THRESHOLD
      ? `Only ${flight.seatsAvailable} ${plural} left`
      : `${flight.seatsAvailable} ${plural} left`;
    seats.classList.toggle('is-low', flight.seatsAvailable <= LOW_SEATS_THRESHOLD);
    button.setAttribute('aria-label', `Book ${flight.flightNumber} departing ${flight.departureTime}`);
    button.addEventListener('click', () => openBooking(flight));
  }
  return fragment;
}

async function searchFlights(event) {
  event?.preventDefault();
  const from = $('#from').value;
  const to = $('#to').value;
  const date = $('#date').value;
  const errorBox = $('#search-error');
  errorBox.hidden = true;

  if (!from || !to) return;
  if (from === to) {
    showAlert(errorBox, 'Origin and destination must be different airports.');
    return;
  }
  if (!date) {
    showAlert(errorBox, 'Please pick a departure date.');
    return;
  }

  const section = $('#results');
  const list = $('#flight-list');
  const status = $('#results-status');
  const submit = $('#search-submit');

  section.hidden = false;
  $('#results-title').textContent = `${cityLabel(from)} → ${cityLabel(to)}`;
  $('#results-meta').textContent = formatDate(date);
  status.replaceChildren();
  status.className = '';
  renderSkeletons(list);
  setLoading(submit, true);
  section.scrollIntoView({ behavior: 'smooth', block: 'start' });

  try {
    const params = new URLSearchParams({ from, to, date });
    const result = await fetchJSON(`${API.search}?${params}`);
    const flights = result.flights || [];
    $('#results-meta').textContent = `${formatDate(result.date)} · ${flights.length} ${flights.length === 1 ? 'flight' : 'flights'}`;
    if (flights.length === 0) {
      list.replaceChildren();
      status.className = 'alert alert-info';
      status.textContent = 'No flights on this day. Try another date.';
    } else {
      list.replaceChildren(...flights.map(renderFlight));
    }
  } catch (err) {
    list.replaceChildren();
    status.className = 'alert alert-error';
    showAlert(status, `Search failed. ${err.message}`, { retry: () => searchFlights() });
  } finally {
    setLoading(submit, false);
  }
}

// --- booking ------------------------------------------------------------------

function flightSummary(flight) {
  const offset = arrivalDayOffset(flight);
  return [
    el('span', { className: 'route', text: `${cityLabel(flight.from)} → ${cityLabel(flight.to)}` }),
    el('span', {
      className: 'details',
      text: `${formatDate(flight.date)} · ${flight.departureTime}–${flight.arrivalTime}${offset ? ` (+${offset})` : ''} · ${flight.flightNumber} · ${formatDuration(flight.durationMinutes)}`,
    }),
  ];
}

function updateTotal() {
  if (!selectedFlight) return;
  const seats = Number($('#seats').value) || 1;
  $('#booking-total').textContent = formatMoney(selectedFlight.price * seats, selectedFlight.currency);
}

function openBooking(flight) {
  selectedFlight = flight;
  const dialog = $('#booking-dialog');

  $('#booking-step').hidden = false;
  $('#confirm-step').hidden = true;
  $('#booking-error').hidden = true;
  $('#booking-flight').replaceChildren(...flightSummary(flight));

  const seats = $('#seats');
  const maxSeats = Math.min(MAX_SEATS_PER_BOOKING, flight.seatsAvailable);
  seats.replaceChildren(
    ...Array.from({ length: maxSeats }, (_, i) => {
      const option = el('option', { text: `${i + 1} ${i === 0 ? 'passenger' : 'passengers'}` });
      option.value = String(i + 1);
      return option;
    }),
  );
  updateTotal();

  const submit = $('#booking-submit');
  setLoading(submit, false);
  submit.textContent = 'Confirm booking';

  dialog.showModal();
  $('#passenger-name').focus();
}

function validateBookingForm() {
  const name = $('#passenger-name');
  const email = $('#email');
  const problems = [];

  const nameValue = name.value.trim();
  const nameOk = nameValue.length >= 2 && nameValue.length <= 80;
  name.setAttribute('aria-invalid', String(!nameOk));
  if (!nameOk) problems.push('Enter the passenger name (2–80 characters).');

  const emailOk = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.value.trim());
  email.setAttribute('aria-invalid', String(!emailOk));
  if (!emailOk) problems.push('Enter a valid email address.');

  return problems;
}

async function submitBooking(event) {
  event.preventDefault();
  const errorBox = $('#booking-error');
  errorBox.hidden = true;

  const problems = validateBookingForm();
  if (problems.length) {
    showAlert(errorBox, problems.join(' '));
    return;
  }

  const submit = $('#booking-submit');
  setLoading(submit, true);
  submit.textContent = 'Booking…';

  try {
    const booking = await fetchJSON(API.bookings, {
      method: 'POST',
      body: {
        flight_id: selectedFlight.id,
        passenger_name: $('#passenger-name').value.trim(),
        email: $('#email').value.trim(),
        seats: Number($('#seats').value),
      },
    });
    showConfirmation(booking);
  } catch (err) {
    showAlert(errorBox, err.message);
    setLoading(submit, false);
    submit.textContent = 'Confirm booking';
  }
}

function bookingEntries(booking, flight) {
  const entries = [];
  if (flight) {
    entries.push(['Route', `${flight.from} → ${flight.to}`]);
    entries.push(['Date', formatDate(flight.date)]);
    if (flight.departureTime) entries.push(['Departs', `${flight.departureTime} · ${flight.flightNumber}`]);
  }
  entries.push(['Passenger', booking.passenger_name]);
  entries.push(['Seats', String(booking.seats)]);
  entries.push(['Total paid', formatMoney(booking.total_price, booking.currency)]);
  return entries;
}

function showConfirmation(booking) {
  $('#booking-step').hidden = true;
  $('#confirm-step').hidden = false;
  $('#confirm-reference').textContent = booking.reference;
  $('#confirm-details').replaceChildren(
    ...detailList([...bookingEntries(booking, booking.flight), ['Email', booking.email]]).childNodes,
  );

  const copy = $('#copy-reference');
  // The Clipboard API only exists in secure contexts (https or localhost).
  copy.hidden = !navigator.clipboard;
  copy.textContent = 'Copy reference';
  copy.onclick = async () => {
    try {
      await navigator.clipboard.writeText(booking.reference);
      copy.textContent = 'Copied!';
    } catch {
      copy.hidden = true;
    }
  };

  // Pre-fill "Find my booking" so the reference is one click away later.
  $('#reference').value = booking.reference;
  $('#confirm-title').focus();
}

function closeDialog() {
  $('#booking-dialog').close();
}

// --- find my booking ----------------------------------------------------------

/** Flight details from the API, or parsed from the id when flight-search is down. */
function flightFromBooking(booking) {
  if (booking.flight) return booking.flight;
  const match = FLIGHT_ID_PATTERN.exec(booking.flight_id || '');
  if (!match) return null;
  const [, flightNumber, from, to, y, m, d] = match;
  return { flightNumber, from, to, date: `${y}-${m}-${d}` };
}

function renderBookingCard(booking) {
  const header = el('div', { className: 'booking-card-header' }, [
    el('p', { className: 'reference', text: booking.reference }),
    el('span', { className: 'status-pill', text: booking.status }),
  ]);
  const entries = bookingEntries(booking, flightFromBooking(booking));
  entries.push(['Email', maskEmail(booking.email)]);
  entries.push(['Booked', formatDateTime(booking.created_at)]);
  return el('div', { className: 'booking-card' }, [header, detailList(entries)]);
}

async function lookupBooking(event) {
  event.preventDefault();
  const input = $('#reference');
  const result = $('#lookup-result');
  const submit = $('#lookup-submit');
  const reference = input.value.trim().toUpperCase();
  input.value = reference;

  if (!REFERENCE_PATTERN.test(reference)) {
    input.setAttribute('aria-invalid', 'true');
    result.replaceChildren(el('div', { className: 'alert alert-error', text: 'A booking reference has 6 letters and digits.' }));
    return;
  }
  input.setAttribute('aria-invalid', 'false');

  setLoading(submit, true);
  try {
    const booking = await fetchJSON(`${API.bookings}/${encodeURIComponent(reference)}`);
    result.replaceChildren(renderBookingCard(booking));
  } catch (err) {
    const message = err.status === 404
      ? `We couldn't find a booking with reference ${reference}.`
      : `Lookup failed. ${err.message}`;
    result.replaceChildren(el('div', { className: 'alert alert-error', text: message }));
  } finally {
    setLoading(submit, false);
  }
}

// --- footer: environment and versions -----------------------------------------

async function loadVersions() {
  const sources = [
    ['version-frontend', '/version.json'],
    ['version-flight-search', '/api/flights/version'],
    ['version-booking-api', '/api/bookings/version'],
  ];

  const results = await Promise.allSettled(sources.map(([, url]) => fetchJSON(url, { timeout: 5000 })));

  results.forEach((result, index) => {
    const target = document.getElementById(sources[index][0]);
    const version = result.status === 'fulfilled' && result.value && result.value.version;
    target.textContent = version || 'unavailable';
    target.classList.toggle('is-unavailable', !version);
  });

  const badge = $('#env-badge');
  const frontend = results[0];
  const environment = frontend.status === 'fulfilled' && frontend.value && frontend.value.environment;
  badge.textContent = environment || 'unavailable';
  // Known environments get a colour; anything else keeps the neutral style.
  const known = ['local', 'dev', 'staging', 'prod'];
  const normalized = environment === 'production' ? 'prod' : environment;
  let variant = 'env-unavailable';
  if (environment) variant = known.includes(normalized) ? `env-${normalized}` : '';
  badge.className = `env-badge ${variant}`.trim();
}

// --- wiring -------------------------------------------------------------------

function init() {
  const dateInput = $('#date');
  const today = new Date();
  const tomorrow = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 1);
  dateInput.min = toISODate(today);
  dateInput.value = toISODate(tomorrow);

  $('#search-form').addEventListener('submit', searchFlights);
  $('#swap').addEventListener('click', () => {
    const from = $('#from');
    const to = $('#to');
    [from.value, to.value] = [to.value, from.value];
  });

  $('#booking-form').addEventListener('submit', submitBooking);
  $('#seats').addEventListener('change', updateTotal);

  const dialog = $('#booking-dialog');
  for (const button of dialog.querySelectorAll('[data-close]')) {
    button.addEventListener('click', closeDialog);
  }
  // Clicking the backdrop (the dialog element itself, outside its content) closes it.
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) closeDialog();
  });

  const referenceInput = $('#reference');
  referenceInput.addEventListener('input', () => {
    referenceInput.value = referenceInput.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
  });
  $('#lookup-form').addEventListener('submit', lookupBooking);

  loadAirports();
  loadVersions();
}

init();
