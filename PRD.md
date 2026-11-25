# PRD v2 — Paper Broker: correct core, fully tested

Status: **draft v2 for review** · Date: 2026-11-23 · Replaces v1 (archived at `docs/PRD-v1.md`).

v1 described what to build and most of it now runs. v2 does not add features. It defines the **exact rules** the simple features must follow, then a **test plan that proves every rule**. Each rule has an ID (`ORD-04`). Every ID must have at least one test that cites it, and CI enforces this (§9.7).

Items marked **[D]** are decisions open for review. Each comes with a recommendation (§11).

---

## 1. What the real brokers do, and what we copy

We compared the brokers that set user expectations for "buy a stock with an app". We only copy the rules that a paper broker with virtual money needs.

| Topic | Interactive Brokers (paper account) | Robinhood | ARQ (formerly DolarApp, LatAm; brokerage through Alpaca) | **Paper Broker v2** |
|---|---|---|---|---|
| Audience | Professionals. The paper account mirrors live trading | Retail, mobile-first | LatAm retail investing in USD | Retail learners |
| Fill model | Fills are simulated from the top of the book. Orders have no market impact, so fills can be better than live ones | Real routing. Dollar orders are market orders in regular hours | Real orders through Alpaca | Instant full fill at the latest real price. Every receipt says "Simulated fill" |
| Fractional / dollar orders | Supported for some products | Dollar or share orders, **$1 minimum**, with a **"Sell all" exception below $1** | Fractional, **from $1** | Same as Robinhood: $1 minimum and an explicit `sell_all` |
| Order types | Many (limit, stop, algorithmic). Some are missing in paper | Market and limit. Extended hours accept limit orders only | Market | **Market only** (limit orders later) |
| Hours | Exchange hours plus extended hours | Regular hours, plus extended hours (about 7:00–9:30 and 16:00–20:00 ET) for eligible orders. Orders placed outside hours are queued | US market hours | Stocks and ETFs: **regular session only**, rejected outside it (no queue). Crypto: 24/7 |
| Fees | Commission schedule | No commission | Says no commission. Its own pages quote different total costs (0.2% to 0.5%) for brokerage and FX | No fees (`FEE_BPS = 0`) |
| Settlement / PDT | Real rules (T+1 settlement, pattern day trader rule on margin accounts) | T+1. Good-faith violations in cash accounts | Cash account | **Not simulated.** Virtual cash settles instantly, so there is no PDT rule and no margin |
| Corporate actions | Applied | Splits and dividends applied | Applied | **Splits applied (new). Dividends not applied** [D3] |
| Funding | Real money | Real money | Local currency converted to USDc | Virtual deposits from $1 to $10M, ignored when computing returns |

Lessons that turned into rules:
1. **Dollar-based buying with a $1 minimum, and "Sell all" as its own action** (Robinhood, ARQ). The current code guesses that a sell order means "sell all" when its amount reaches the position's value. That guess is replaced by an explicit flag (ORD-05).
2. **Be honest about simulation** (IBKR documents that paper fills can beat real ones). The UI says "Simulated fill at last price" (UX-07).
3. **Real prices break when a split happens.** After a 10:1 split, the provider's price falls 90% while our stored quantity stays the same. Every broker adjusts positions for splits. We have to as well (CA-01..05).
4. **Stocks trade in regular hours only**, and the closed state is explained clearly (Robinhood queues instead. We reject and show the next open time, and queueing is for later).

Sources: [IBKR paper trading limitations](https://www.interactivebrokers.com/support/faq/content/limitations-paper-trading-account-35807733) · [IBKR paper trading (API docs)](https://www.interactivebrokers.com/docs/tws-api/doc/notes-limitations/limitations/paper-trading) · [IBKR: executions that did not match the market](https://www.interactivebrokers.com/support/faq/content/1112354621) · [Robinhood fractional shares](https://robinhood.com/us/en/support/articles/fractional-shares) · [Robinhood extended hours](https://robinhood.com/us/en/support/articles/360001226766/extendedhours-trading) · [Robinhood market orders](https://robinhood.com/eu/en/support/articles/market-order) · [What is ARQ](https://www.arqfinance.com/help/articles/what-is-arq) · [What is ARQ Invest](https://www.arqfinance.com/help/articles/what-is-arq-invest) · [ARQ: investing in US stocks (pt-BR)](https://arqfinance.com/articles/como-investir-em-acoes-americanas/). Settlement and PDT facts are general US market rules. Check the exact hours and fees on the live pages before quoting them to users.

---

## 2. Scope

### In scope (must work perfectly)
Signup and login, $100,000 starting cash, deposits, asset search and detail with real prices and charts, **market buy and sell by amount, quantity or sell-all**, positions with average cost and realized and unrealized P&L, order history, portfolio value history with a SPY benchmark, watchlist, account reset, **stock splits**.

### Out of scope (unchanged from v1)
Limit and stop orders, queued orders, extended hours, dividends, short selling, margin, options, fees, multiple portfolios, social features, real money, email verification and password reset [D6].

### Quality bar
- Every rule in §3–§7 has an ID and at least one automated test that cites it.
- Money must never be wrong by even one cent. Ledger invariants (MON-05, MON-06) are checked by tests, randomized tests and a rake task that can run against any database.
- No real network calls in automated tests (except one optional nightly smoke job, §9.6).

---

## 3. Money and numbers (MON)

| ID | Rule |
|---|---|
| MON-01 | Every money value, quantity and price is `decimal` in Postgres and `BigDecimal` in Ruby. **No Float in money code paths**: a spec greps `app/services` and `app/models` for `to_f`/`Float(` and fails on a match. |
| MON-02 | Scales: cash and totals have **2 dp**, quantity **8 dp**, price **8 dp**, percentages **2 dp** in the API (4 dp stored). |
| MON-03 | The API sends every decimal as a **string** with a fixed scale (`"100000.00"`, `"0.50000000"`). The frontend never computes a number that goes back to the server as truth. It only sends what the user typed. |
| MON-04 | Rounding. **Buy by amount**: `total = amount` (exact), `quantity = floor(amount / price, 8)`. **Buy or sell by quantity**: `total = round_half_up(quantity × price, 2)`. **Sell all**: `quantity = held`, `total = round_half_up(held × price, 2)`. **Realized P&L**: `round_half_up((price − avg_cost) × quantity, 2)`. **Average cost** on a buy: `round_half_up((q_old × avg_old + q_new × price) / (q_old + q_new), 8)`. |
| MON-05 | **Cash ledger invariant**, always true since the last reset: `cash = Σ deposits − Σ buy totals + Σ sell totals`. |
| MON-06 | **Position invariant**: for each asset, `quantity = Σ buy qty − Σ sell qty`, adjusted by recorded split ratios. A position exists only when its quantity is > 0. |
| MON-07 | The database enforces `cash >= 0`, `quantity > 0`, `deposit.amount > 0`, and `order.total > 0`, `order.quantity > 0` and `order.price > 0` (the last three are new). |
| MON-08 | `rake ledger:verify` checks MON-05 and MON-06 for every account and exits non-zero on any mismatch. CI runs it after the E2E suite. |

---

## 4. Accounts and authentication (AUTH)

| ID | Rule |
|---|---|
| AUTH-01 | Signup creates the user, the account, an `initial` deposit of `STARTING_CASH` and a first snapshot in **one transaction**. A failure leaves nothing behind. |
| AUTH-02 | The email is trimmed, lowercased and unique regardless of case. The name is 1–80 characters. The password is **8–72 bytes** (bcrypt ignores anything after 72 bytes, so longer passwords are rejected). |
| AUTH-03 | A failed login returns the same message and timing whether or not the email exists (`unauthenticated`, "Incorrect email or password."). |
| AUTH-04 | Rate limits use the Rails 8 `rate_limit`: login 10 per 3 min per IP, signup 5 per hour per IP. Over the limit, the API returns **429 `rate_limited`**. |
| AUTH-05 | The session cookie is `pb_session`: signed, HttpOnly, SameSite=Lax, Secure in production, 30-day expiry. Logout deletes the server-side session, so a replayed cookie returns 401. |
| AUTH-06 | **CSRF defense**: every POST or DELETE must have `Content-Type: application/json` (for DELETE, an `Accept: application/json` header and a same-origin `Origin`). Otherwise the API returns **415 `unsupported_media_type`**. |
| AUTH-07 | Every endpoint except `signup`, `session#create`, `market/status` and `up` returns 401 without a session. **No endpoint can read or change another user's data.** Every resource is scoped to `current_account`, and each endpoint has a test that tries cross-user access. |
| AUTH-08 | Reset (RST) and logout do not affect other users. Deleting a user cascades to all of their rows. |

---

## 5. Trading (ORD)

### 5.1 Request
`POST /orders` with `{symbol, side, quantity}` or `{symbol, side, amount}` or `{symbol, side: "sell", sell_all: true}`, plus the **required** header `Idempotency-Key`.

| ID | Rule |
|---|---|
| ORD-01 | Only market orders are accepted. `side` is `buy` or `sell`. **Exactly one** of `quantity`, `amount` or `sell_all` (sell only) must be given, otherwise `validation_failed`. |
| ORD-02 | Input precision: `amount` has at most **2 dp** and `quantity` at most **8 dp**. More decimals return `validation_failed` (no silent rounding). Values must be > 0 and finite. Exponent notation and strings like `"1e3"`, `"NaN"` and `" "` are rejected. |
| ORD-03 | The symbol is not case-sensitive. An unknown or inactive asset returns `not_found`. |
| ORD-04 | **Minimum notional is $1.00**, checked on the computed `total`. If quantity rounds down to 0, the order is also `below_minimum`. **Exception:** `sell_all` has no minimum (it can close dust positions). |
| ORD-05 | **Sell all** sells exactly the held quantity. A sell by `amount` or `quantity` above the holding returns `insufficient_quantity` with `details.max_quantity` and `details.max_amount`. The UI then offers "Sell all". There is no implicit sell-all heuristic. |
| ORD-06 | A buy whose `total > cash` returns `insufficient_funds` with `details.max_amount = cash`. |
| ORD-07 | Selling an asset with no position returns `insufficient_quantity` (held 0). |

### 5.2 Price and hours
| ID | Rule |
|---|---|
| ORD-10 | The fill price is the stored quote price at fill time. The quote must be **fresh**: `fetched_at` no older than 60 s. Otherwise the backend fetches a new one **before** taking the account lock (no network calls inside a DB transaction). |
| ORD-11 | The quote must also be **current**. For stocks and ETFs during the regular session, `as_of` must be within **15 min**. For crypto, `as_of` must be within **5 min**. Otherwise the order is `price_unavailable`. This catches trading halts and frozen feeds even when the fetch itself succeeded. |
| ORD-12 | If the provider fails (timeout of 5 s, non-2xx response or unparseable body), the result is `price_unavailable` (503). **No made-up prices are ever used.** |
| ORD-13 | Stocks and ETFs trade only while `MarketCalendar.open?` is true (CAL rules). Otherwise the order is **queued** (QUE rules): it is stored as `pending` and fills at the first fresh price after the open. If the calendar knows no next session, it is `market_closed` with `details.next_open: null`. Crypto trades 24/7. *(Supersedes decision D1 of v2: reject when closed. Changed on request: a beginner must be able to place an order in the evening.)* |
| ORD-14 | Market status is checked **again inside the lock**, using the same `now`, so an order that straddles 16:00:00 is decided by a single timestamp. |

### 5.3 Execution
| ID | Rule |
|---|---|
| ORD-20 | One DB transaction with `SELECT … FOR UPDATE` on the account: re-check idempotency, validate cash or quantity, create the order, update cash, update the position, record a snapshot. |
| ORD-21 | **Concurrency**: N parallel orders whose combined cost exceeds cash produce fills only up to the available cash. Cash never goes below 0. Parallel sells never sell more than the holding. |
| ORD-22 | **Buys**: the average cost is weighted (MON-04). **Sells**: the average cost does not change, the realized P&L is stored on the order, and the position is deleted when its quantity reaches 0. A buy after a full close starts a new average cost. |
| ORD-23 | A filled order is **immutable**: there is no update or delete endpoint, and model callbacks block changes to filled orders. |
| ORD-24 | **Idempotency**: keys are scoped per account and are 1–255 printable characters. They are kept until account reset. The same key with the **same** request body returns the original order with **200** (the first call returns **201**). The same key with a **different** body returns **422 `idempotency_conflict`**. A request that was rejected (any 4xx/5xx) stores nothing, so retrying with that key runs again. A missing key returns **422 `idempotency_key_required`**. |
| ORD-25 | The response includes the order, the new `cash`, and `position` (or `null` after a full close), so the UI can update without refetching. |

### 5.4 Order history
| ID | Rule |
|---|---|
| ORD-30 | `GET /orders` is newest first (`filled_at desc, id desc`), 25 per page, with `side` and `symbol` filters. An invalid filter returns `validation_failed` instead of being ignored. Pagination is stable while new orders arrive (the `id` tie-breaker). |

---

### 5.5 Queued orders (QUE)

| ID | Rule |
|---|---|
| QUE-01 | A stock or ETF order placed while the market is closed is accepted with HTTP 201 and `status: "pending"`. `quantity`, `price`, `total` and `filled_at` are `null`; `amount`, `requested_quantity`, `sell_all` and `reserved_cash` describe the request. Crypto never queues. |
| QUE-02 | Queued orders are idempotent exactly like instant ones (ORD-24): same key and body replays with 200, a different body is `idempotency_conflict`. |
| QUE-03 | Validation at queue time: the same input rules as ORD-02, the $1 minimum, holdings for sells. If the price is unknown, orders sized by quantity or sold by amount are `price_unavailable`; orders sized by dollars do not need a price. |
| QUE-04 | Cash is reserved when a buy is queued: the dollar amount, or 105% of the estimate for quantity-sized buys. Spendable cash is `cash − reserved`. No order, instant or queued, may spend reserved cash. |
| QUE-05 | A sell is queued against the quantity held. Only one waiting sell per asset; a `sell_all` waiting order blocks others. At most 20 pending orders per account (`too_many_pending_orders`). |
| QUE-06 | Pending orders fill oldest first once the market is open, using the normal price rules (ORD-10..12) and rounding (MON-04). The job runs every minute; reads of orders and portfolio also settle them. If no usable price exists yet the order stays pending. |
| QUE-07 | `DELETE /orders/:id` cancels a pending order and releases its reservation. Repeating it returns 200. Cancelling a filled or rejected order is 409 `order_not_pending`. |
| QUE-08 | If at fill time the order can no longer be executed (cash, quantity, minimum), it becomes `rejected` with a human `reject_reason` and its reservation is released. Cash and positions are untouched. |
| QUE-09 | Pending, cancelled and rejected orders never change cash or positions; `Ledger::Verify` counts filled orders only. A filled queued order follows MON-05/06 like any other. |

## 6. Market data, calendar and corporate actions

### Market data (MKT)
| ID | Rule |
|---|---|
| MKT-01 | All providers implement one interface: `quote`, `quotes`, `candles(range)`, `history(from)`, `splits(from)`. The adapters are Yahoo (stocks, ETFs, all history and splits) and CoinGecko (crypto quotes). |
| MKT-02 | Each adapter parses a **recorded fixture** of the real response in tests. Missing or null fields raise `ProviderError`. They never return 0 or nil as a price. |
| MKT-03 | Refresh cadence (unchanged from v1): crypto every 60 s, active stocks every 60 s while the market is open, the rest every 15 min. The job **skips if the previous run is still going** (advisory lock). |
| MKT-04 | **Valuation never uses made-up prices.** If a held asset has no quote, the position is returned with `price: null`, `price_status: "missing"`, and is excluded from `total_value`, which carries `"incomplete": true`. (The current fallback to average cost is removed.) |
| MKT-05 | A quote older than 2 min carries `stale: true`, and the UI shows its age. |
| MKT-06 | Candles are cached: intraday ranges for 5 min, daily ranges until the next close. Provider failure on candles returns 503 `price_unavailable`, and the UI shows a retry. |

### Calendar (CAL)
| ID | Rule |
|---|---|
| CAL-01 | The regular session runs 09:30:00 (inclusive) to 16:00:00 (exclusive) America/New_York, Monday to Friday. It is computed in that zone, so it stays correct across both DST changes. |
| CAL-02 | NYSE full holidays are listed in code through at least 2027. |
| CAL-03 | **Early closes are modelled** (new): 13:00 ET on the day after Thanksgiving, on Christmas Eve when it is a weekday, and on July 3 when applicable, per the NYSE published list. |
| CAL-04 | **Fail safe**: for a date past the end of the table, the market counts as **closed** and an error is logged. A CI test fails when the table ends within 180 days of the build date. |
| CAL-05 | `GET /market/status` returns `{open, next_open, next_close, session: "regular"|"closed", early_close: bool}`. |

### Corporate actions (CA), new
| ID | Rule |
|---|---|
| CA-01 | A daily job (06:00 ET) fetches split events for every asset that is **held** by any account, plus SPY, since the last check. |
| CA-02 | Each split is stored once in `corporate_actions(asset_id, kind: "split", ratio decimal, effective_date)`, which is unique on `(asset_id, kind, effective_date)`. Running it again does nothing. |
| CA-03 | It applies to each position open at the effective date: `quantity × ratio` (floored to 8 dp), `average_cost ÷ ratio` (8 dp), and a `position_adjustments` row for the audit trail. Cost basis (`qty × avg`) is preserved within $0.01. |
| CA-04 | Splits run **before** the market opens on the effective date. Valuation, MON-06 and the benchmark account for them. History charts use split-adjusted provider data. |
| CA-05 | Dividends are not applied [D3]. The SPY benchmark also uses **price only**, so the comparison is fair. |

---

## 7. Cash, performance, watchlist, reset

### Deposits (DEP)
| ID | Rule |
|---|---|
| DEP-01 | The amount is between $1.00 and $10,000,000.00 with at most 2 dp. Anything else returns `validation_failed` or `below_minimum`. |
| DEP-02 | The same idempotency semantics as ORD-24 apply, and the key is **required**. |
| DEP-03 | Cash rises by exactly the amount. A ledger row is added and a snapshot recorded, all in one transaction. |
| DEP-04 | Deposits never change any return figure (PERF-03/04). |

### Performance (PERF)
| ID | Rule |
|---|---|
| PERF-01 | `total_value = cash + Σ(quantity × quote.price)` (MKT-04 when a quote is missing). |
| PERF-02 | `day_change = Σ quantity × (price − previous_close)` over positions held. `day_change_percent = day_change / (total_value − day_change)`. |
| PERF-03 | `total_return = total_value − net_deposits`. `total_return_percent = total_return / net_deposits × 100`. |
| PERF-04 | Range return: `start` is the **last snapshot at or before the range start**, or else the first snapshot in the range. `D` is the deposits after `start.taken_at`. `gain = now_value − start.total_value − D` and `pct = gain / (start.total_value + D)`. When there is no snapshot, gain is 0. |
| PERF-05 | Snapshots are taken hourly (in dev, every `SNAPSHOT_SCHEDULE`) for accounts whose held market is open, once after the close (16:05 ET) for every account, and on signup, each fill, each deposit and each reset. At most one close snapshot is taken per account per day. |
| PERF-06 | The history series ends with a live point at `now`. The series is sorted by time with no duplicate timestamps. |
| PERF-07 | Benchmark: each deposit buys SPY units at the SPY price at the deposit time (the last bar at or before it). The benchmark value at time t is `Σ units × SPY price at t`, adjusted for splits. If SPY history is unavailable, the response returns `benchmark: null` with `benchmark_error`, not an error for the whole request. |
| PERF-08 | Accepted ranges are `1D|1W|1M|1Y|ALL`. Anything else returns `validation_failed`. |

### Watchlist (WL) and reset (RST)
| ID | Rule |
|---|---|
| WL-01 | Adding an asset that is already watched returns 200 and leaves one row. Deleting an asset that isn't watched returns 204. An unknown symbol returns `not_found`. |
| RST-01 | The body must be `{confirm: "RESET"}` (case-sensitive). |
| RST-02 | **Atomic** (fixes the current code): one transaction deletes positions, orders, deposits, snapshots and idempotency keys, sets `cash = STARTING_CASH`, creates the `initial` deposit and a snapshot, and sets `reset_at`. The watchlist and the user stay. |
| RST-03 | After a reset, MON-05 and MON-06 hold and the dashboard shows the new-account empty state. |

### API conventions (API)
| ID | Rule |
|---|---|
| API-01 | Error body: `{error: {code, message, details?}}`. Codes: `unauthenticated` 401, `not_found` 404, `validation_failed` 422, `insufficient_funds` 422, `insufficient_quantity` 422, `below_minimum` 422, `market_closed` 422, `idempotency_conflict` 422, `idempotency_key_required` 422, `unsupported_media_type` 415, `rate_limited` 429, `price_unavailable` 503, `internal` 500 (no stack traces). |
| API-02 | `backend/openapi.yml` is the contract. Request specs validate **every response** against it (the `committee` gem), and frontend types are generated from it (`openapi-typescript`). CI fails if the generated types differ from the committed ones. |
| API-03 | Timestamps are UTC ISO 8601 with a `Z` suffix. |

---

## 8. UX rules that tests must check (UX)

| ID | Rule |
|---|---|
| UX-01 | The trade ticket shows a live estimate (quantity for amount input, total for quantity input) labelled "Estimated". The receipt shows the **actual** fill values from the server. |
| UX-02 | The confirm button is disabled during the request. Double-clicking or retrying after a timeout reuses the **same** idempotency key, so there is exactly one order. A new key is created only when the ticket's inputs change. |
| UX-03 | `insufficient_funds` shows the inline message and a one-tap "Use max $X". `insufficient_quantity` shows "Sell all". |
| UX-04 | For a stock while the market is closed, the buttons read "Queue buy" / "Queue sell" and the page says "Market opens Mon 9:30 AM ET (in 14h 20m)" and that the order is queued and can be cancelled. The review step repeats it, and the receipt says "Order queued … nothing has been bought or sold yet". Crypto is unaffected. |
| UX-05 | When a price is stale or unavailable, a "Delayed" tag appears and trading is disabled for that asset. |
| UX-06 | Gains and losses always show a sign and an arrow as well as a colour. Numbers use tabular figures. |
| UX-07 | Receipts and the trade ticket say "Simulated fill at last price. Virtual money." A persistent "Virtual money" badge sits in the header. |
| UX-08 | Every page works at **375 px**, by keyboard only, in light and dark themes, and passes **axe** with no serious or critical violations. |
| UX-09 | Every query has a loading state (skeleton), an empty state and an error state with retry. |
| UX-10 | Polling runs every 15 s for the portfolio and visible quotes, and pauses while the tab is hidden. |

---

## 9. Test strategy

### 9.1 Pyramid and tools

| Layer | Backend | Frontend | Runs |
|---|---|---|---|
| Unit | RSpec on services, models, `MarketCalendar`, `Fmt`, presenters, provider parsers (fixtures) | Vitest on `lib/format`, input parsing, estimate math, the idempotency-key hook | Every push, < 30 s |
| Property / randomized | RSpec with `rantly` (or a seeded `Random` loop): random sequences of deposits, buys, sells, splits and resets, checking MON-05, MON-06 and MON-07 after each step | — | Every push, 200 sequences × 30 steps, seed printed |
| Integration | Request specs for **every endpoint × every error code × auth**, with responses checked against `openapi.yml`. Job specs. Concurrency specs (real threads and DB connections, no transactional fixtures) | Component tests with Testing Library and **MSW** handlers typed from OpenAPI. `vitest-axe` on every component | Every push |
| Contract | `committee` response validation (API-02) and a type-drift check | Generated types compile | Every push |
| E2E | Playwright against the full Docker stack running the **scripted provider** (§9.4) | — | Every PR (Chromium desktop and mobile). Nightly: WebKit too |
| Live smoke | Nightly calls to real Yahoo and CoinGecko through the adapters, to detect schema drift | — | Nightly. Not required to merge |

Determinism rules: freeze time with `travel_to` for every time-dependent spec, block the network with WebMock (`disable_net_connect!`), print the random seed, and never sleep in tests (poll with timeouts in Playwright).

### 9.2 Required unit tests (minimum list)

**`Orders::Place`**: buy by amount, buy by quantity and sell all, each at a normal price, a tiny price (0.00012345) and a huge price (BTC above 100k). Rounding cases for every MON-04 formula, including a half-cent tie. Below minimum when quantity rounds to 0. Sell all on dust under $1 (ORD-04). Over-sell by amount and by quantity (ORD-05). Insufficient funds with exact `max_amount`. Weighted average across 3 buys. Average cost unchanged on a sell. Realized P&L sign for a gain, a loss and break-even. Position deleted at 0, then a re-buy starts a fresh average. Input rejections (ORD-02): 3 dp amount, 9 dp quantity, `"1e3"`, `"-1"`, `"0"`, `""`, `null`, both fields, neither field. Stale `fetched_at` triggers a refetch. Stale `as_of` gives `price_unavailable` (ORD-11). Provider error gives `price_unavailable` (ORD-12). Stock when closed gives `market_closed` with `next_open`. Crypto when closed fills. An order at 15:59:59.999 fills and one at 16:00:00 is rejected (ORD-14).

**`MarketCalendar`**: a table-driven spec with one row per case: weekday open, pre-open 09:29:59, open 09:30:00, close 15:59:59 and 16:00:00, weekend, each 2026 and 2027 holiday, each early close at 12:59:59 and 13:00:00, the spring-forward and fall-back days, `next_open` across a long weekend, and fail-safe past the end of the table (CAL-04). A guard test checks that the table covers at least 180 days ahead.

**Performance**: hand-computed fixtures for PERF-01..04 and PERF-07, covering no snapshots, a deposit inside the range, a deposit before the range, an account younger than the range, and a split inside the range.

**Corporate actions**: 2:1, 10:1, reverse 1:10, a fractional ratio of 3:2, idempotent re-run, a split on an asset nobody holds, and cost basis preserved (CA-03).

**Providers**: parse the recorded fixture for each endpoint. Null price, missing `meta`, HTTP 429, HTTP 500, timeout and malformed JSON each raise `ProviderError`.

**Frontend**: `format` for negative values, zero, very large values, many-decimal crypto and locale grouping. Amount and quantity parsing matches ORD-02, so the UI blocks what the API would reject. The idempotency-key hook keeps a stable key across retries and creates a new one when inputs change (UX-02).

### 9.3 Required integration tests

- **Request specs**: one file per controller. Each endpoint covers success, 401, every error code it can emit, cross-user access (AUTH-07), response schema (API-02), and 415 for a non-JSON POST (AUTH-06).
- **Idempotency** (ORD-24, DEP-02): same key and same body returns 200 and one row. Same key with a different body returns 422. A rejected order followed by a retry with the same key fills. Two parallel requests with the same key give one row.
- **Concurrency** (ORD-21): 10 threads each buy $20k on $100k, giving exactly 5 fills and cash at 0. 10 threads each sell half of a position, giving exactly 2 fills. A deposit in parallel with a buy keeps the ledger consistent.
- **Atomic signup and reset** (AUTH-01, RST-02): inject a failure halfway through, and no partial rows remain.
- **Jobs**: the quote refresh skips when the lock is held, the close snapshot is never taken twice in a day, and the splits job is idempotent.
- **Ledger**: `rake ledger:verify` passes on a seeded database and fails on a database with a deliberately corrupted row.
- **Frontend components**: TradeSheet (all paths in UX-01..05 against MSW: success receipt, each error, double-click sends one request), Dashboard (empty, loaded, error, incomplete valuation), Markets search, DepositSheet, Settings reset confirmation.

### 9.4 E2E environment (deterministic, real stack)

The rule "no mock data in the running app" stays for **development and production**. For E2E only:
- The app boots with `RAILS_ENV=e2e` and `MARKET_DATA_PROVIDER=scripted`. A boot check **refuses** to load the scripted provider in any other environment, and a spec proves it.
- The test-only routes under `/__e2e__/` are drawn **only** in `e2e`: `POST /__e2e__/reset` (truncate and seed), `POST /__e2e__/clock {now}` (the app reads time through `Clock.now`), `POST /__e2e__/prices {symbol: price, as_of}`, `POST /__e2e__/provider {symbol, fail: true}`, `POST /__e2e__/split {symbol, ratio, date}`.
- Playwright uses `docker compose -f docker-compose.e2e.yml up`, one worker per isolated user (signup per test), and a trace on failure.
- After the suite: `rake ledger:verify` must pass.

### 9.5 E2E scenarios (each cites rule IDs)

| ID | Scenario |
|---|---|
| E2E-01 | Sign up → dashboard shows $100,000.00 and the empty state (AUTH-01, UX-09) |
| E2E-02 | Wrong password → generic error. Log out → back button cannot open the dashboard (AUTH-03, AUTH-05) |
| E2E-03 | Search "apple" and "AAPL" → asset page shows the price and chart (MKT) |
| E2E-04 | Market open, buy $1,000 AAPL by amount → receipt with the actual values, cash down by exactly $1,000.00, position visible (ORD, UX-01, UX-07) |
| E2E-05 | Buy by quantity, then sell half → average cost unchanged and realized P&L shown in Activity (ORD-22) |
| E2E-06 | Sell all, including a sub-$1 dust position → position gone (ORD-04, ORD-05) |
| E2E-07 | Clock set to Saturday → AAPL trading disabled with the next open time; BTC buy works (ORD-13, UX-04) |
| E2E-08 | Buy more than cash → inline error → "Use max" → fills at the max (ORD-06, UX-03) |
| E2E-09 | Double-click Confirm with the network throttled → exactly one order (UX-02, ORD-24) |
| E2E-10 | Provider failing for TSLA → "Delayed", trading disabled, a direct API call returns 503 (ORD-12, UX-05) |
| E2E-11 | Deposit $5,000 → cash +5,000, total return unchanged (DEP, PERF-03) |
| E2E-12 | Advance the clock and change prices → chart has points, range tabs work, SPY overlay appears (PERF) |
| E2E-13 | 2:1 split on a held stock → quantity doubled, average halved, value continuous (CA) |
| E2E-14 | Watchlist add and remove, persisted after reload (WL) |
| E2E-15 | Reset with the wrong word is refused; with "RESET" the account returns to $100k and empty (RST) |
| E2E-16 | J1–J7 at 375 px (mobile project), keyboard-only buy flow, axe scan on every page in both themes (UX-08) |
| E2E-17 | Market-close boundary: clock 15:59:50, open the ticket, clock 16:00:01, confirm → `market_closed` shown cleanly (ORD-14) |

### 9.6 Nightly live smoke
Each adapter calls the real provider for AAPL, SPY and BTC, checks the shape and that price > 0, and fetches SPY splits. Failures open an issue and do not block merges.

### 9.7 Coverage and gates (CI must pass to merge)
- Backend: SimpleCov **≥ 95% lines and ≥ 90% branches overall**, and **100% branches** for `Orders::Place`, `Deposits::Create`, `Portfolios::Valuate`, `MarketCalendar`, `CorporateActions::ApplySplit`, and the reset service.
- Frontend: Vitest coverage **≥ 85% lines** on `src/lib` and `src/components`.
- **Rule traceability**: `script/rule_coverage` collects every rule ID in this PRD and fails if any ID is not cited in at least one spec or test name or tag (`it "... [ORD-04]"`, Playwright `@ORD-04`).
- Also required: RuboCop, Brakeman, bundler-audit, `tsc`, ESLint, the OpenAPI type-drift check, and E2E with `ledger:verify`.
- **CI lives at the repo root** (`.github/workflows/ci.yml`). The current `backend/.github/` is never picked up by GitHub, so it moves.

---

## 10. Changes this PRD requires in the current code

1. `Orders::Place`: explicit `sell_all` replaces the amount-based guess. Reject instead of rounding (ORD-02). Add the `as_of` currency check (ORD-11). Re-check the market inside the lock (ORD-14). Return 200 on replay and handle payload conflicts (ORD-24). Make the idempotency key required.
2. `Portfolios::Valuate`: remove the fallback to average cost when a quote is missing (MKT-04).
3. `AccountsController#reset`: make it atomic (RST-02). Today the initial deposit runs after the transaction commits.
4. `MarketCalendar`: early closes (CAL-03), fail safe (CAL-04), `Clock.now` seam.
5. New: `corporate_actions` and `position_adjustments` tables, a splits job, and `splits` in the providers.
6. New: rate limits (AUTH-04), the JSON content-type guard (AUTH-06), new error codes, `openapi.yml` with `committee`, password max 72 bytes.
7. New migrations for MON-07 constraints. Store a request hash with the idempotency key (ORD-24).
8. Test infrastructure: `spec/`, factories, recorded fixtures, SimpleCov, the e2e environment and routes, Playwright, MSW, root CI, `rake ledger:verify`, `script/rule_coverage`.
9. Repo hygiene: `git init`, a `.gitignore` (exclude `config/master.key`, `log/`, `tmp/`, `node_modules/`), a fixed `.env.example`, and a real `backend/README.md`.

### Delivery order
| Phase | Content | Done when |
|---|---|---|
| T0 | Repo hygiene, root CI, RSpec, Vitest, SimpleCov, fixtures, `Clock` | CI green on an empty suite |
| T1 | Unit and integration tests for the **current** behaviour (characterization) | Coverage ≥ 80% |
| T2 | Rule changes 1–4, 6–7, test-first | Every MON/AUTH/ORD/DEP/PERF/RST/CAL rule cited and passing |
| T3 | Corporate actions (CA) | CA tests and E2E-13 green |
| T4 | E2E environment and E2E-01..17, a11y | Full gate (§9.7) green on PR |

---

## 11. Decisions to make together

| # | Question | Recommendation |
|---|---|---|
| D1 | Outside market hours, **reject** stock orders or **queue** them for the open (as Robinhood does)? | Reject for now. Queueing brings in cancellation, price moves and expiry, which is a feature of its own. |
| D2 | Fill at the **last price**, or simulate a **bid/ask spread** (buy at ask, sell at bid)? | Last price. Yahoo's free data has no reliable bid/ask. Say "simulated" in the UI (UX-07). |
| D3 | Apply **dividends**? | Not yet. Splits are required for correctness, dividends are not. The benchmark is price-only so the comparison stays fair. |
| D4 | Make `Idempotency-Key` **required** (breaking change for API clients)? | Yes. The only client is our SPA, which already sends it. |
| D5 | Add the `e2e` environment with a scripted provider and test routes? This bends the "no mock data" rule, but only inside tests. | Yes. Without it, E2E cannot test market-closed, provider failure, splits or exact amounts reliably. |
| D6 | Email verification and password reset? | Leave them out while the app is private. They are needed before any public launch. |
| D7 | Coverage thresholds (95/90/100 backend, 85 frontend): too strict or right? | Keep them. The app is small and money code must be exhaustively tested. |
| D8 | Extended hours? | Leave them out. Robinhood only allows limit orders there, and we don't have limit orders. |
