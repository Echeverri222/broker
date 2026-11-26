// SCL-01..04. Run with: k6 run loadtest/scenario.js -e BASE_URL=https://staging.example.com
import http from "k6/http";
import { check, sleep } from "k6";
import { Trend } from "k6/metrics";

const BASE = __ENV.BASE_URL || "http://localhost:8080";
const USERS = Number(__ENV.USERS || 200);
const history = new Trend("portfolio_history_ms", true);
const orders = new Trend("order_ms", true);

export const options = {
  scenarios: {
    // SCL-01: 200 concurrent tabs polling.
    tabs: { executor: "constant-vus", vus: Math.min(USERS, 200), duration: "10m", exec: "browse" },
    // SCL-01: 50 orders/min sustained, then 200/min for 5 minutes.
    trading: {
      executor: "ramping-arrival-rate", startRate: 50, timeUnit: "1m", preAllocatedVUs: 50, maxVUs: 200,
      stages: [{ target: 50, duration: "5m" }, { target: 200, duration: "5m" }], exec: "trade",
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.001"],                       // SCL-04
    "http_req_duration{kind:read}": ["p(95)<150"],         // SCL-03
    order_ms: ["p(95)<400"],                               // SCL-03
    portfolio_history_ms: ["p(95)<300"],                   // SCL-03
  },
};

const json = { headers: { "Content-Type": "application/json", Accept: "application/json" } };

function signup() {
  const email = `loadtest-${__VU}-${Date.now()}-${Math.floor(Math.random() * 1e6)}@example.com`;
  const res = http.post(`${BASE}/api/v1/signup`, JSON.stringify({ name: "Load", email, password: "loadtest-pass-1" }), json);
  check(res, { "signed up": (r) => r.status === 201 });
}

export function browse() {
  if (!http.cookieJar().cookiesForURL(BASE).pb_session) signup();
  const read = (path) => http.get(`${BASE}/api/v1${path}`, { tags: { kind: "read" } });
  read("/me"); read("/portfolio"); read("/orders?limit=20"); read("/watchlist");
  const h = http.get(`${BASE}/api/v1/portfolio/history?range=1M`, { tags: { kind: "history" } });
  history.add(h.timings.duration);
  sleep(15); // SCL-12: 15 s polling while the tab is on screen
}

export function trade() {
  if (!http.cookieJar().cookiesForURL(BASE).pb_session) signup();
  const symbol = ["SPY", "AAPL", "MSFT", "NVDA", "BTC"][Math.floor(Math.random() * 5)];
  const res = http.post(`${BASE}/api/v1/orders`, JSON.stringify({ symbol, side: "buy", amount: "50" }),
    { headers: { ...json.headers, "Idempotency-Key": `lt-${__VU}-${__ITER}-${Date.now()}` }, tags: { kind: "order" } });
  orders.add(res.timings.duration);
  check(res, { "order accepted": (r) => r.status === 201 || r.status === 200 || r.status === 422 });
}
