# Paper Broker — local MVP

Virtual money, simulated market. See `PRD.md`. Rails 8 API + Solid Queue + Postgres, React/Vite SPA, all in Docker.

## Real data only
No mock data and no simulated prices anywhere. Prices come from real providers, no API key needed:
- **Stocks / ETFs / all price history:** Yahoo Finance chart endpoint (unofficial, no SLA, fine for a prototype; swap for a licensed feed before any public launch).
- **Crypto quotes:** CoinGecko public API (set `COINGECKO_API_KEY` to a free demo key for higher limits).
- If a provider fails, orders are rejected with `price_unavailable`; the app never falls back to made-up prices.
- Stocks trade only during real NYSE hours (no override); crypto 24/7.

## Run
```
docker compose up --build
```
Open http://localhost:5173 (API also on :3000). Needs internet access. First boot takes a few minutes.
Reset everything: `docker compose down -v`.

## Implemented
Signup/login, $100,000 initial deposit, deposits any time (idempotent), ~54 real assets with typo-tolerant search, market orders by
amount or quantity (row-locked, idempotent), **queued orders** (a stock order placed while NYSE is closed waits, reserves cash,
fills at the first fresh price after the open, and can be cancelled; max 20 waiting), positions with average cost and realized P&L,
portfolio history vs SPY, "Today" change that only counts moves since purchase, watchlist, order/deposit history, account reset,
light/dark theme, responsive layout, corporate actions, and an OpenAPI contract (`backend/openapi.yml`) checked in specs.

## UI v3 (docs/PRD-ui-v3.md)
- **Theme**: all colours are CSS variables in `frontend/src/index.css` (light `:root`, dark `:root[data-theme="dark"]`). An inline script in `index.html` sets `data-theme` from `localStorage.pb_theme` (or the OS setting) before first paint, so there is no flash. Switch it from the account menu or Settings > Appearance (Light / Dark / Match device).
- **Screens**: Home (greeting, markets strip, portfolio chart vs S&P 500, accounts, waiting orders, holdings, checklist), Markets (filters, quick picks, sort, sector, URL state, Show more), Asset (Line/Area/Candles, candle size, volume, SMA 10/20, compare, your trades, key numbers, sticky trade panel; bottom sheet on phones), Welcome, Settings. Cmd/Ctrl+K opens the symbol search.
- **New or changed endpoints** (all in `backend/openapi.yml`, v3.0.0): `GET /assets` (kind, filter, sector, sort, page, limit; cache only; returns `meta.counts`, `meta.sectors`, `meta.fuzzy`), `GET /assets/:symbol` (adds `sector`, `stats`), `GET /assets/:symbol/candles` (`interval` = 1h|1d|1w, volume per candle, response `interval`), `GET /market/overview` (S&P 500 via SPY, Nasdaq via QQQ, Bitcoin), `GET /orders` (`status`, `limit`), `GET /portfolio/history` (adds `3M`).
- **Warm job**: `WarmMarketDataJob` (hourly at minute 7, see `config/recurring.yml`) caches 1y overview data (30-day sparkline, 52-week range, volume, averages, 1m/1y change) per asset. `db/seeds.rb` runs it once; to refresh by hand: `bin/rails runner 'MarketData::Warm.call'`. The list endpoint never calls a provider.

## Develop
```
cd backend && export RBENV_VERSION=3.4.6 DATABASE_USER=$USER   # .ruby-version asks for 3.4.12; any 3.4.x works
bundle exec rspec && bundle exec rubocop
cd ../frontend && npm run gen:api && npx tsc --noEmit && npx vitest run
cd .. && ruby script/rule_coverage      # every rule ID (PRD.md and docs/PRD-ui-v3.md) must be cited by a test
cd frontend && npm run check:api         # generated types must match backend/openapi.yml (also runs in CI)
```

## Multi-user (docs/PRD-v4-multi-user.md)
Per-device sessions (hashed, expiring, listable and revocable), password reset and email confirmation by signed token, change
password, email preferences, data export and account deletion, rate limits, append-only audit log, admin API (15-minute
re-authentication, asset toggle, kill switch), public `/api/v1/status`, `/up/deep` readiness and bearer-protected `/metrics`.
Scale: the request path never calls a provider; jobs own provider traffic behind a circuit breaker, fan out per account on
`critical`/`default`/`low` queues, and the SPA polls every 15 s while active and every 60 s when idle.
Ops: `deploy/` (nginx, compose, smoke test, alert rules), `loadtest/`, `docs/runbook.md`. Every PRD rule ID must be cited
by a test: `ruby script/rule_coverage`.

### v4 deviations
- Deferred (documented in `script/rule_coverage`): SCL-07 (snapshots still run inside the order transaction) and SES-09 (account reset still hard-deletes).
- SCL-12: the `GET /home` summary endpoint is not built; only adaptive polling is.
- CAL-06: no calendar table; NYSE holidays remain in code.
- OBS-01: no error-tracker gem; errors go through `Rails.error`, so a subscriber can be added without code changes.
- SEC-03: throttled requests answer 429 (the PRD text said otherwise).

## Deviations from the PRD
- PRD v2 decisions D1-D8 were assumed from its recommendations. **D1 is reversed**: orders placed while the market is closed are queued (PRD §5.5, QUE-01..09) instead of rejected.
- Orders rejected at validation time are returned as errors, not stored; a queued order that cannot fill at the open is stored as `rejected` with a reason.
- Deposits are new (virtual money); `net_deposits` replaces `starting_cash` in the API.
- No fake provider: prices are real (Yahoo); if a provider fails, trading pauses rather than invent a price.
- Not done yet: Playwright E2E suite, coverage thresholds in CI, component tests for DepositSheet.

### UI v3 deviations
- Candle volume and stats for crypto come from Yahoo (`SYMBOL-USD`), not CoinGecko, so volume is not null for crypto. CoinGecko is still used for quotes.
- `week52_position` is a 4-decimal string (not a float) to keep money-like values out of floats.
- The default 1D candle size is 5m (reported in the response `interval`); the request enum is `1h|1d|1w`.
- Extra API fields: `meta.fuzzy` and per-row `watched` on `GET /assets`. "Most traded" means the top 10 by volume. Quick picks combine with AND. "Showing results for X" uses the top match's name, because the API does not return a corrected term.
- Stats are read from the warm cache; there is no lazy provider call on a cold start (fields show an en dash until the job has run).
- Compare on the asset page rebases both series (including candles, as OHLC) to the first close and shows a % axis. Home overlays the S&P 500 line in dollars instead.
- The Watchlist nav item opens `/markets?show=watching`. Watch on Home opens Markets with the search focused.
- The password-strength hint is the static "At least 8 characters." on Welcome plus a line in Settings (there is no change-password feature).
- Sparkline colour follows the line (first vs last point), not today's change.
- The asset page last candle can differ from the live quote when the cached candles are older than the quote.
- Bundle is a single ~690 kB chunk (no code splitting).

### Browser verification (QA-06)
Checked in Chrome at desktop width, dark theme: Home, Markets (filters and sparklines), Asset with Line and Candles (tooltip, queued order panel, key numbers). Not checked in a real browser: 390px width (the window resize did not change the viewport), light theme, Welcome, Area, volume/SMA/compare overlays, and placing an order. Those are covered only by unit and axe tests (jsdom).
