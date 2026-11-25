# PRD — Paper Broker (working name)

A simulated brokerage: virtual money, real market prices. Users buy and sell stocks, ETFs and crypto with a virtual cash balance and watch how their decisions perform over time.

Status: draft v1 · Date: 2026-11-11

---

## 1. Goals and non-goals

### Goals
1. **Feel real.** Prices come from live market data; orders fill at the real current price; stocks follow real market hours.
2. **Measure over time.** Every account has a value history, so the user can see return over 1D / 1W / 1M / 1Y / All and compare against a benchmark (S&P 500 via SPY).
3. **Excellent UX.** Placing a trade takes under 10 seconds and three interactions. Every screen is fast, legible and works on a phone.
4. **Simple to build.** Small scope, one clear contract between backend and frontend, so independent agents can implement in parallel.

### Non-goals (MVP)
- Real money, withdrawals, KYC, any regulated activity. (Virtual **deposits** are in scope: users can add cash at any time; returns exclude deposits.)
- Limit / stop orders, short selling, margin, options, dividends, stock splits.
- Social features, leaderboards, multiple portfolios per user.
- Native mobile apps (responsive web only).
- Streaming prices over WebSockets (polling is enough).

These are candidates for later versions (see §11).

---

## 2. Users and core journeys

One persona: a person who wants to practice investing without risk.

| # | Journey | Success looks like |
|---|---------|--------------------|
| J1 | Sign up | Account created with **$100,000** virtual cash, lands on dashboard in < 30 s |
| J2 | Discover an asset | Search by name or ticker, see price, change and chart |
| J3 | Buy | Enter a dollar amount or quantity, review, confirm, see the position immediately |
| J4 | Sell | From a position, sell part or all, see cash updated |
| J5 | Track performance | Dashboard shows total value, return, chart over time, benchmark comparison |
| J6 | Review history | List of every order with price, quantity, time |
| J7 | Watch | Add assets to a watchlist to follow without buying |

---

## 3. Product rules

These are binding for implementation. Where a rule is a judgment call it is marked *(decision)*.

### Accounts
- One portfolio per user, in USD.
- Starting cash: $100,000 (config value `STARTING_CASH`).
- "Reset account" in settings: wipes positions, orders and history, restores starting cash. Requires typed confirmation.

### Assets
- A **curated universe** seeded in the database *(decision)*: about 40 US stocks/ETFs (must include SPY) and about 15 major cryptocurrencies. This keeps API usage inside free tiers and keeps search quality high. Adding an asset is a seed/admin change.
- Asset kinds: `stock`, `etf`, `crypto`.

### Orders
- **Market orders only**, buy or sell.
- The user can enter either a **dollar amount** or a **quantity**. Fractional quantities are allowed for all assets (8 decimal places).
- An order fills immediately and fully at the latest price, provided the quote is fresh:
  - Fresh means fetched within the last 60 s. If stale, the backend fetches a new quote before filling. If the provider fails, the order is rejected with `price_unavailable`.
- **Stocks/ETFs trade only while the US market is open** (NYSE regular hours, holidays respected). Outside hours the order is rejected with `market_closed` and the UI shows when the market opens next *(decision: queueing orders for the open is v1.1)*.
- **Crypto trades 24/7.**
- No fees, no slippage *(decision; `FEE_BPS` config exists and defaults to 0)*.
- Validation: buys cannot exceed cash; sells cannot exceed held quantity; minimum order value $1.
- Order placement is one database transaction with a row lock on the account: create order, update cash, update position. It must be impossible to double-spend with concurrent requests.
- Orders are idempotent: the client sends an `Idempotency-Key` header; a repeated key returns the original order.

### Positions and P&L
- A position holds `quantity` and `average_cost` (weighted average, updated on buys, unchanged on sells).
- Unrealized P&L = (price − average_cost) × quantity. Realized P&L is recorded on each sell order.
- A position with quantity 0 is deleted.

### Performance
- Portfolio value = cash + Σ(quantity × latest price).
- **Snapshots**: a job records each account's total value, cash and invested value. Hourly while any market the user holds is open, and once daily at US market close for everyone. Snapshots power the performance chart.
- Total return = (value − net starting cash) / starting cash. Time-range return uses the first snapshot in the range.
- Benchmark: the chart can overlay "what if the same $100,000 were in SPY since account creation".

### Money and numbers
- All money and quantities are `decimal` in Postgres and `BigDecimal` in Ruby. Never floats. The API returns them as **strings**; the frontend formats them and never does arithmetic that gets sent back as truth.
- Timestamps are UTC ISO 8601. The frontend displays in the user's local time zone.

---

## 4. Architecture

```
frontend/  React SPA (Vite)  ──HTTP JSON──▶  backend/  Rails API  ──▶  PostgreSQL
                                                  │
                                                  ├─ Solid Queue jobs (price refresh, snapshots)
                                                  └─ Market data adapters ──▶ external price APIs
```

Monorepo with two top-level folders: `backend/` and `frontend/`, plus `docker-compose.yml` for Postgres and a root `README.md` with one-command setup.

### Backend
- Ruby on Rails 8 (API mode), PostgreSQL 16+.
- **Solid Queue** (Rails 8 default, database-backed) for background jobs. No Redis.
  - Recurring schedules (quote refresh, snapshots) use Solid Queue's built-in recurring tasks in `config/recurring.yml`.
  - Recurring jobs must be idempotent and must not pile up: a refresh job skips if the previous run is still in progress.
  - Mission Control Jobs is mounted at `/jobs` for inspecting queues, restricted to development or an authenticated admin.
- Solid Cache (database-backed) for quote and candle caching.
- Authentication: Rails 8 built-in authentication (`has_secure_password`, session records), delivered as an HTTP-only, SameSite=Lax cookie. In development the Vite dev server proxies `/api` to Rails so everything is same-origin.
- Tests: RSpec, FactoryBot, WebMock (no real network calls in tests).
- Business logic lives in service objects (`Orders::Place`, `Portfolios::Valuate`, `Snapshots::Record`), not in controllers or models.

### Frontend
- React 19 + TypeScript + Vite.
- Tailwind CSS + shadcn/ui components.
- TanStack Query for server state (polling), React Router for routes, React Hook Form + Zod for forms.
- Charts: TradingView `lightweight-charts` for price and performance charts.
- Tests: Vitest + Testing Library for components, Playwright for the J1–J6 end-to-end flow.

### Market data
All providers sit behind one interface so they can be swapped without touching the rest of the app:

```ruby
MarketData.quote(asset)            # => Quote(price:, change:, change_percent:, as_of:)
MarketData.quotes(assets)          # batch
MarketData.candles(asset, range:)  # => [Candle(time:, open:, high:, low:, close:)]
MarketData.market_status           # => { open:, next_open:, next_close: }
```

Proposed providers (all have free tiers; **the implementing agent must verify current limits and terms before coding the adapter**):

| Need | Provider | Notes |
|------|----------|-------|
| Stock/ETF quotes, market status | Finnhub | Per-symbol quote endpoint, generous per-minute limit |
| Stock/ETF history (candles) | Twelve Data | Daily credit cap; fetch rarely, cache hard |
| Crypto quotes and history | CoinGecko | One batch call covers all coins |

Rules for staying inside free tiers:
- The frontend **never** calls a provider. It only calls our API.
- A recurring job refreshes quotes into the `quotes` table: crypto every 60 s; stocks every 60 s during market hours and only for assets that are held, watched, or viewed in the last 10 minutes; the rest every 15 minutes.
- Candles are cached: intraday ranges for 5 minutes, daily ranges until the next market close.
- **No mock or simulated data in the running app**: prices always come from real providers. Test doubles are allowed in automated tests only.
- API keys live in environment variables (`FINNHUB_API_KEY`, `TWELVE_DATA_API_KEY`, `COINGECKO_API_KEY`), documented in `.env.example`.

---

## 5. Data model

| Table | Key columns |
|-------|-------------|
| `users` | `email` (unique, citext), `password_digest`, `name` |
| `sessions` | `user_id`, `token`, `user_agent`, `ip_address` |
| `accounts` | `user_id` (unique), `cash` decimal(20,2), `starting_cash` decimal(20,2), `reset_at` |
| `assets` | `symbol` (unique), `name`, `kind` (stock/etf/crypto), `provider_ref`, `logo_url`, `active` |
| `quotes` | `asset_id` (unique), `price` decimal(20,8), `previous_close`, `change_percent`, `as_of`, `fetched_at` |
| `positions` | `account_id`, `asset_id` (unique together), `quantity` decimal(28,8), `average_cost` decimal(20,8) |
| `orders` | `account_id`, `asset_id`, `side` (buy/sell), `quantity`, `price`, `total` decimal(20,2), `realized_pnl`, `status` (filled/rejected), `reject_reason`, `idempotency_key` (unique per account), `filled_at` |
| `portfolio_snapshots` | `account_id`, `total_value`, `cash`, `invested_value`, `taken_at` (indexed with account) |
| `watchlist_items` | `user_id`, `asset_id` (unique together) |
| `asset_views` | `asset_id`, `viewed_at` (drives refresh priority; may be a cache key instead of a table) |

Database constraints: `cash >= 0`, `quantity > 0`, foreign keys everywhere, enums as Postgres enums or checked strings.

---

## 6. API contract (v1)

Base path `/api/v1`. JSON. Cookie session. This contract is the boundary between backend and frontend agents: change it only by updating this section first.

Errors: `{ "error": { "code": "insufficient_funds", "message": "Human readable text" } }` with status 401 / 404 / 422 / 503.
Error codes: `unauthenticated`, `not_found`, `validation_failed`, `insufficient_funds`, `insufficient_quantity`, `market_closed`, `price_unavailable`, `below_minimum`.

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/signup` | `{name, email, password}` → user; creates account with starting cash |
| POST | `/session` | `{email, password}` → user |
| DELETE | `/session` | Sign out |
| GET | `/me` | Current user + account summary |
| GET | `/market/status` | `{open, next_open, next_close}` for US equities |
| GET | `/assets?q=&kind=` | Search/list assets with latest quote |
| GET | `/assets/:symbol` | Asset detail, quote, user's position (if any), watched flag |
| GET | `/assets/:symbol/candles?range=1D\|1W\|1M\|3M\|1Y\|5Y` | Price history |
| GET | `/portfolio` | Cash, total value, day change, total return, positions with live P&L |
| GET | `/portfolio/history?range=1D\|1W\|1M\|1Y\|ALL&benchmark=SPY` | Snapshot series, optional benchmark series |
| GET | `/orders?page=` | Order history, newest first |
| POST | `/orders` | `{symbol, side, quantity}` **or** `{symbol, side, amount}` + `Idempotency-Key` header → filled order |
| GET | `/watchlist` | Watched assets with quotes |
| POST | `/watchlist` | `{symbol}` |
| DELETE | `/watchlist/:symbol` | Remove |
| GET | `/deposits` | Deposit ledger, newest first |
| POST | `/deposits` | `{amount}` (+ optional `Idempotency-Key`) → deposit; adds cash |
| POST | `/account/reset` | `{confirm: "RESET"}` |

Example — `GET /portfolio`:

```json
{
  "cash": "42150.25",
  "total_value": "103422.10",
  "invested_value": "61271.85",
  "day_change": "512.40",
  "day_change_percent": "0.50",
  "total_return": "3422.10",
  "total_return_percent": "3.42",
  "positions": [
    {
      "symbol": "AAPL", "name": "Apple Inc.", "kind": "stock",
      "quantity": "25.50000000", "average_cost": "218.40000000",
      "price": "231.12000000", "market_value": "5893.56",
      "unrealized_pnl": "324.36", "unrealized_pnl_percent": "5.82",
      "day_change_percent": "0.84", "quote_as_of": "2026-11-11T15:42:10Z"
    }
  ]
}
```

The backend agent delivers an OpenAPI file (`backend/openapi.yml`) matching this table in its first milestone; the frontend generates TypeScript types from it.

---

## 7. UX / UI

### Principles
1. **The number that matters is the biggest thing on the screen.** Portfolio value on the dashboard, price on the asset page.
2. **Three interactions to trade.** Open asset → enter amount → confirm.
3. **Never leave the user guessing.** Every price shows its age if older than 2 minutes; closed markets are stated plainly with the next open time; every error says what to do next.
4. **Calm, not casino.** No confetti, no urgency prompts. Green/red only for gains/losses, always paired with a sign (+/−) and arrow so it is not color-only.
5. **Instant feedback.** Skeleton loaders (no spinners on whole pages), optimistic watchlist toggles, a toast and updated balances right after a fill.
6. **A persistent "Virtual money" badge** in the header so nobody mistakes this for a real brokerage.

### Screens

| Route | Screen | Contents |
|-------|--------|----------|
| `/welcome` | Landing + sign up / sign in | One-sentence pitch, form, nothing else |
| `/` | Dashboard | Total value, day and total return, performance chart with range tabs and SPY overlay toggle, positions list, watchlist, cash |
| `/markets` | Markets | Search box (autofocus, `/` shortcut), tabs All / Stocks / ETFs / Crypto, rows with logo, name, price, day change, sparkline |
| `/assets/:symbol` | Asset detail | Price, change, chart with range tabs, "Your position" card, Buy / Sell buttons, watch toggle, market status |
| (sheet) | Trade ticket | Buy/Sell toggle, amount-or-quantity input with switch, live estimate, available cash / quantity, "Max" shortcut, Review → Confirm |
| `/activity` | Activity | Order history, filter by side and asset |
| `/settings` | Settings | Name, theme, reset account, sign out |

The trade ticket is a side sheet on desktop and a bottom sheet on mobile. After confirm it shows a receipt (quantity, price, total, new cash) with "Done" and "View position".

### Empty and edge states (required, not optional)
- New account dashboard: "You have $100,000 to invest" with a button to Markets and three suggested assets.
- Market closed on a stock: Buy/Sell disabled with "Market opens Mon 9:30 AM ET (in 14h 20m)". Crypto unaffected.
- Price unavailable: last known price with "Delayed" tag; trading disabled for that asset.
- Insufficient funds: inline under the input, with the maximum affordable amount offered as a one-tap fix.

### Visual design
- Light and dark themes, following the system by default.
- One typeface (Inter), tabular numerals for every number.
- Neutral gray palette, one accent color, green and red reserved for P&L.
- Layout: left sidebar on desktop, bottom tab bar on mobile (Dashboard, Markets, Activity, Settings).
- Accessibility: WCAG AA contrast, full keyboard navigation, visible focus, `aria-live` on trade confirmations, respects `prefers-reduced-motion`.

### Performance targets
- Dashboard interactive in < 1.5 s on a warm backend.
- API p95 < 200 ms for reads (they hit the database only, never a provider).
- Polling: portfolio and visible quotes every 15 s, paused when the tab is hidden.

---

## 8. Milestones

Each milestone ends with a working, demoable app.

| Milestone | Scope | Demo |
|-----------|-------|------|
| **M0 Foundations** | Repo scaffold, Postgres via docker-compose, Solid Queue running a test job, Rails API + Vite app boot, CI (lint + tests), OpenAPI file, design tokens and app shell, `FakeProvider` | Both apps start with one command; shell renders |
| **M1 Market data** | Assets seed, provider adapters, quote refresh job, candles with caching, market status, Markets + Asset detail screens | Browse real prices and charts |
| **M2 Trading** | Auth, accounts, orders service, positions, trade ticket, Activity screen | Sign up, buy, sell, see history |
| **M3 Performance** | Snapshot jobs, portfolio history + benchmark, Dashboard, watchlist | See value over time vs SPY |
| **M4 Polish** | Empty/edge states, dark mode, accessibility pass, reset account, Playwright E2E, README | Full J1–J7 pass on desktop and mobile |

---

## 9. Work packages for implementing agents

Packages inside the same milestone can run in parallel. The API contract (§6) and product rules (§3) are the shared source of truth; an agent that needs to deviate updates this PRD first.

| ID | Package | Owns | Depends on |
|----|---------|------|------------|
| A1 | Backend scaffold | `backend/` Rails app, DB config, Solid Queue + Solid Cache setup, RSpec, CI, `openapi.yml`, error format | — |
| A2 | Frontend scaffold | `frontend/` Vite app, Tailwind, shadcn/ui, router, app shell, theme, API client + generated types, MSW mocks from the OpenAPI file | — |
| B1 | Market data | `MarketData` interface, three adapters + `FakeProvider`, `quotes` table, refresh jobs, candle cache, market status, assets seed, asset endpoints | A1 |
| B2 | Markets UI | Markets screen, Asset detail, chart component, search | A2 (uses mocks until B1 lands) |
| C1 | Auth + accounts | Signup/session endpoints, account creation, `/me` | A1 |
| C2 | Trading engine | `Orders::Place`, positions, order endpoints, idempotency, concurrency tests | B1, C1 |
| C3 | Trading UI | Auth screens, trade ticket, receipt, Activity screen | A2, B2 |
| D1 | Performance backend | Snapshot jobs, `/portfolio`, `/portfolio/history`, benchmark series, watchlist endpoints | C2 |
| D2 | Dashboard UI | Dashboard, performance chart, watchlist | C3 |
| E1 | Polish + E2E | Edge states, a11y, reset account, Playwright suite, README | all |

### Definition of done (every package)
- Tests written and passing; no real network calls in tests.
- Backend: `rubocop` clean; request specs cover success and each error code for the endpoints touched.
- Frontend: `tsc` and `eslint` clean; loading, empty and error states implemented for every screen touched.
- Behavior matches §3 and §6 exactly; any deviation is recorded in this PRD.
- Run instructions in the README still work from a clean checkout.

---

## 10. Acceptance criteria (MVP)

1. A new user signs up and sees $100,000.00 cash and an empty-state dashboard.
2. Searching "apple" or "AAPL" finds Apple; the asset page shows a price no older than 2 minutes during market hours.
3. Buying $1,000 of BTC at any hour creates a position worth about $1,000 and reduces cash by exactly $1,000.00.
4. Buying a stock while the US market is closed is refused with the next open time shown.
5. Buying more than available cash is refused; selling more than held is refused.
6. Two simultaneous buy requests that together exceed cash result in exactly one fill.
7. Repeating a request with the same `Idempotency-Key` creates one order.
8. Selling half a position leaves average cost unchanged and records realized P&L.
9. After snapshots exist, the dashboard chart shows value over time with range tabs and a SPY overlay.
10. Order history lists every order with correct price, quantity, total and time.
11. Every screen is usable at 375 px width and by keyboard only, in light and dark themes.
12. If a provider is unreachable, trading that asset is refused with `price_unavailable`; no synthetic price is ever shown or used.
13. A user can deposit additional virtual cash at any time; cash rises by exactly the deposit and total return is unaffected by it.

---

## 11. Later (not in MVP)

Queued orders for market open · limit and stop orders · dividends and splits · price alerts · multiple portfolios · leaderboards and sharing · fees and slippage simulation · more markets and currencies · live streaming prices · installable PWA.

---

## 12. Open questions

1. **Product name** — "Paper Broker" is a placeholder.
2. **Market data providers** — the Finnhub + Twelve Data + CoinGecko split is a proposal based on free tiers; confirm limits and terms of use (especially for anything public-facing) before M1.
3. **Hosting** — not decided; the app only needs Postgres, one Rails process, one job worker and static hosting for the SPA.
4. **Starting cash** — fixed $100,000, or let the user choose at signup?
5. **Email** — is email verification / password reset needed for MVP, or is it a private app for a few users?
