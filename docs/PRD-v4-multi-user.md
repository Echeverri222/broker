# PRD v4: Many users. Safe, scalable, operable

Status: **draft for review** · Date: 2026-11-25 · Builds on `PRD.md` (v2: rules and queued orders) and `docs/PRD-ui-v3.md` (UI). Nothing in v2 or v3 may regress.

v2 made the trading core correct. v3 made it pleasant. Both assumed one user on one laptop. v4 is about the moment a second, then the thousandth, user arrives. It does not add trading features. It makes the existing product survive real users, real traffic and a real provider quota, and gives the operator the tools to run it.

Rules have IDs (`SES-03`). Every ID must be cited by at least one test, enforced by `script/rule_coverage` (§10). Items marked **[D]** are open decisions with a recommendation (§11).

---

## 1. Summary

| | |
|---|---|
| Problem | The app works for one user. Several things degrade or break with many: shared provider quota is spent on request paths, background jobs are serial and share one queue, sessions never expire, there is no password reset, nothing is deployable, and nobody can see what is happening. |
| Goal | Run a **closed beta of up to 1,000 users** (200 concurrent) on a single small production deployment, with no data loss, no cross-user leaks, a bounded provider cost, and an operator who can see problems before users report them. |
| Non-goals | Real money, limit/stop orders, fees or slippage, options, social features, mobile apps, KYC. A leaderboard is a stretch item (P2, [D4]). |
| Success | The capacity targets in §3 pass in a load test, `ledger:verify` is clean after it, and the exit criteria of each phase in §9 are met. |

---

## 2. Investigation: what we found

Evidence is from reading the code at `/broker` on 2026-11-25. Nothing was load tested. Numbers marked *estimate* are arithmetic from the code, and §9 Phase 1 turns them into measurements. Severity: **S1** breaks or leaks under multiple users, **S2** degrades, **S3** hygiene.

### 2.1 Provider and request-path problems

| # | Finding | Where | Sev |
|---|---|---|---|
| F1 | `GET /assets/:symbol` calls the provider **inside the request** when the quote is older than 60 s. There is no lock or coalescing, so N users opening the same cold asset make N Yahoo calls. | `assets_controller.rb:51-52`, `quotes/refresh.rb:28` | S1 |
| F2 | `Orders::Place#usable_quote!` also fetches inline. `FillPending` runs this per pending order, so at the 9:30 open with stale quotes, **every queued order can trigger its own provider call**. Crypto is worse: `MarketData.quote` fetches one coin per call, against a free CoinGecko quota. | `orders/place.rb` (usable_quote!), `orders/fill_pending.rb` | S1 |
| F3 | The Yahoo provider makes **one HTTP request per equity symbol** (4 threads). The background cost is fixed (about 38 requests per minute for the current universe) and does not grow with users. Good. But it is an unofficial endpoint with no SLA and the README already says it must be replaced before launch. | `yahoo_provider.rb`, README | S1 |
| F4 | `GET /portfolio` and `GET /orders` run `Orders::FillPending` for the account: **a GET that writes**. Cheap while the market is closed, but at the open every open tab triggers fills and snapshots. | `portfolio_controller.rb`, `orders_controller.rb` | S2 |
| F5 | The dashboard polls 4 queries every 15 s per tab (portfolio, history with benchmark, pending orders, watchlist), plus 2 every 60 s. *Estimate*: 200 concurrent tabs is about 55 requests/s. One Puma process with 3 threads at about 50 ms each handles about 60/s. **The first 200 concurrent users saturate the API with no headroom.** | `frontend/src/lib/query.ts`, `Dashboard.tsx` | S1 |
| F6 | `history` with `benchmark=SPY` loads every snapshot in the range into memory and valuates the account live on every poll. `ALL` is unbounded. | `portfolios/history.rb` | S2 |

### 2.2 Jobs and data growth

| # | Finding | Where | Sev |
|---|---|---|---|
| F7 | All recurring jobs run on **one queue, one worker process, 3 threads**. `WarmMarketDataJob` sleeps 0.25 s per asset (about 14 s plus 54 provider calls) and `SnapshotsJob` loops all accounts serially. Either can delay `FillPendingOrdersJob` and `RefreshQuotesJob`. | `config/queue.yml`, `recurring.yml`, `warm.rb` | S1 |
| F8 | `FillPending.call` (no account) fills all pending orders **one by one in one job**. At the open, 500 queued orders run serially, each taking a row lock and a snapshot. | `orders/fill_pending.rb` | S2 |
| F9 | A **snapshot is written on every fill and deposit** and each one valuates the entire portfolio. Hourly snapshots add rows for every account holding something open. *Estimate*: one crypto holder is about 8,800 rows a year, so 10,000 such accounts is about 88 million rows a year, with no retention or downsampling. The dev schedule (every 5 min) is about 105,000 rows a year per account. | `snapshots/record.rb`, `record_all.rb` | S2 |
| F10 | `Accounts::Reset` **hard-deletes** orders, deposits and snapshots. After a reset the ledger has no evidence of past activity and `ledger:verify` can no longer detect earlier corruption. | `accounts/reset.rb` | S2 |
| F11 | **Calendar time bomb.** `MarketCalendar::COVERED_THROUGH` is 2027-12-31. After it, `CAL-04` treats every day as closed, `closed?` raises `market_closed`, and no stock order can ever be placed or filled. This is 13 months away and silent. | `market_calendar.rb` | S1 (dated) |

### 2.3 Accounts, sessions and abuse

| # | Finding | Where | Sev |
|---|---|---|---|
| F12 | Sessions have **no server-side expiry**, are never pruned, and store the token in plain text. Only the cookie is signed and set to 30 days. There is no "log out everywhere". | `session.rb`, `application_controller.rb` | S2 |
| F13 | **No password reset, change password, email verification or account deletion.** v2 deferred these (D6) "until any public launch". This is that launch. | `PRD.md` D6, README | S1 |
| F14 | Rate limits exist only for signup and login, keyed by `request.remote_ip`. Behind a load balancer whose address is public, `remote_ip` can be the balancer, so **all users share one bucket**. Nothing limits authenticated endpoints (orders, search, candles, deposits). Login has no per-email limit, so one IP rotation defeats it. | `signups_controller.rb`, `sessions_controller.rb` | S1 |
| F15 | Deposits are free and capped at $10M each with no daily cap. Account reset has no cooldown. A single user can create unbounded rows. | `deposits/create.rb` | S3 |
| F16 | No roles, no admin. Support, abuse handling and fixing a stuck order need a Rails console. | n/a | S2 |
| F17 | **Authorization is sound.** Every controller scopes through `current_account`, and AUTH-07 requires a cross-user test per endpoint. We keep this and add a generated check so a new endpoint cannot ship without one (SEC-05). | `application_controller.rb` | ok |

### 2.4 Deployment and operations

| # | Finding | Where | Sev |
|---|---|---|---|
| F18 | **No production image.** Only `Dockerfile.dev` exists (source bind-mounted, Vite dev server serving the SPA). No static frontend build is deployed. | `Dockerfile.dev`, `docker-compose.yml` | S1 |
| F19 | `cors.rb` is fully commented out, `config.hosts` is commented out in production, and `ALLOWED_ORIGINS` is the only CSRF origin config. A split-origin deployment currently has no working CORS or cookie story. | `cors.rb`, `production.rb` | S1 |
| F20 | **No error tracking, metrics or alerting.** `rescue_from StandardError` logs and returns 500, so real bugs are invisible. `/up` only proves the process is alive, not that the database, queue or provider work. | `application_controller.rb` | S1 |
| F21 | `ledger:verify` runs only in CI against test data. Nothing checks production money for drift. | `ci.yml` | S2 |
| F22 | **The directory is not a git repository.** A CI workflow and `.gitignore` exist but nothing is tracked. `config/master.key` and `log/` sit in the tree, protected only by an ignore file that is not yet in effect. | repo root | S1 |
| F23 | Stale or stray files: `AssetPage.tsx.bak` in `src/`, committed-looking `coverage/` and `log/`, and `.env.example` still describing `FakeProvider` and `MARKET_OVERRIDE`, which no longer exist. The backend README says "real data only" but the e2e provider that v2 §9 promised (D5) was never built. | various | S3 |
| F24 | Single Postgres in a Docker volume, no backups, and cache, queue and data share one server. | `docker-compose.yml` | S1 |

### 2.5 Test coverage of the above

The suite has about 150 examples and a good concurrency spec (10 parallel buys, ORD-21/24). It has **no** load test, **no** E2E suite (`frontend/e2e` does not exist), no test for session expiry, job overlap, provider quota, backup restore or the calendar boundary. v2's own "not done" list (Playwright, coverage thresholds in CI) is still open.

---

## 3. Capacity targets (the "several users" definition)

Targets for the closed beta. They define "done" for Phase 1.

| ID | Target |
|---|---|
| SCL-01 | **Users**: 1,000 registered, **200 concurrent** (open tabs polling), 50 orders/minute sustained, 200 orders/minute for 5 minutes. |
| SCL-02 | **Market-open burst**: 500 queued orders from 300 accounts all fill within **60 seconds** of 9:30:00 ET, with at most **one provider call per asset** (not per order). |
| SCL-03 | **Latency (server-side, p95)**: reads under 150 ms, `POST /orders` under 400 ms, `GET /portfolio/history` under 300 ms, measured at 200 concurrent users. |
| SCL-04 | **Error budget**: under 0.1% 5xx over a 15-minute window at target load. |
| SCL-05 | **Provider budget**: total provider calls per minute are constant in user count. Equities at most 60/min, crypto at most 2/min plus on-demand coalesced refreshes. Documented against each provider's published limits. |
| SCL-06 | **Integrity**: `ledger:verify` reports zero problems after every load run. |

---

## 4. Scope and priorities

| Priority | Theme | Rule groups |
|---|---|---|
| **P0** (blocks any multi-user launch) | Provider isolation, job architecture, deployability, sessions and account lifecycle, abuse limits, observability, calendar | MKD, JOB, OPS, SES, SEC, OBS, CAL |
| **P1** (needed before public beta) | Snapshot economics, read-path load, admin tools, notifications, backups and restore | SCL, ADM, NTF, DR |
| **P2** (optional) | Leaderboard, licensed data feed, extra benchmarks | LDR, MKD-08 |

---

## 5. Market data isolation (MKD)

The principle: **the request path never calls a provider.** Jobs own provider traffic, and requests read the database. Only a single, coalesced fallback is allowed when data is missing.

| ID | Rule |
|---|---|
| MKD-01 | `GET /assets/:symbol` reads the stored quote and never calls a provider. If the quote is older than 60 s it returns the stored quote with `stale: true` and enqueues **one** refresh job for that asset (deduplicated, MKD-02). |
| MKD-02 | Refreshes are coalesced per asset: at most one in-flight refresh per asset and at most one provider call per asset per 30 s regardless of how many requests or users ask. Implemented with a per-asset lock (advisory lock or `Rails.cache` with `race_condition_ttl`). A spec runs 20 parallel requests for a cold asset and asserts one provider call. |
| MKD-03 | `Orders::Place` and `FillPending` use the stored quote only. A buy or sell requires a quote that satisfies the existing freshness rules (ORD-10..12). If the stored quote is stale the order **fails with `price_unavailable` and enqueues one refresh**. Queued orders stay queued. They never trigger a provider call themselves. |
| MKD-04 | `RefreshQuotesJob` is the only periodic provider caller for quotes. Equities: priority assets (held, watched, recently viewed) every 60 s while open, others every 15 min. Crypto: **one batched call per minute**. A single job run makes at most one call per equity symbol and one crypto batch. |
| MKD-05 | Before the open (9:29:30 ET on trading days) a `PreOpenRefreshJob` refreshes every asset that has a pending order, so the burst in SCL-02 starts with fresh prices. |
| MKD-06 | Provider calls go through one gateway (`MarketData::Gateway`) that adds: a per-provider token bucket (configured from the provider's limit), a circuit breaker (open after 5 consecutive failures, half-open after 30 s), and a response budget counter exported as a metric (OBS-03). When the breaker is open, quotes stay as stored and are flagged stale. Trading is disabled for those assets (UX-05). |
| MKD-07 | Candles and history keep their cache (`candles/v3`, `history/v1`) but are filled with **single-flight** semantics: concurrent misses for the same key wait for one fetch. |
| MKD-08 | **[D3]** The provider interface stays as is (`quote`, `quotes`, `candles`, `history`, `splits`, `overview`) so a licensed feed can replace Yahoo/CoinGecko without touching callers. A contract spec runs the same expectations against each provider's recorded fixtures. |

---

## 6. Jobs and scale (JOB, SCL)

### 6.1 Jobs

| ID | Rule |
|---|---|
| JOB-01 | Queues are split: `critical` (fill orders, pre-open refresh), `default` (quote refresh, snapshots), `low` (warm market data, cleanup, backups). Workers are configured `critical` first, with a dedicated thread so a slow `low` job can never delay a fill. |
| JOB-02 | `FillPendingOrdersJob` selects accounts with pending orders and enqueues **one `FillAccountOrdersJob` per account**. Each is idempotent and takes the account lock. SCL-02 is tested with 300 accounts. |
| JOB-03 | `SnapshotsJob` fans out one `SnapshotAccountJob` per account in batches (`find_in_batches`) and uses `Valuate` with preloaded positions and quotes (no N+1). |
| JOB-04 | Jobs are safe to run twice. Recurring jobs that must not overlap (`RefreshQuotes`) take a lock and skip. Failures retry with backoff (`retry_on`) up to 5 times and then land in a visible failed-jobs list (ADM-04, OBS-04). |
| JOB-05 | The job worker count and thread count are environment variables with documented defaults and a sizing note (threads per DB pool, §8 OPS-05). |
| JOB-06 | Remove side effects from reads: `GET /portfolio` and `GET /orders` no longer call `FillPending`. Settlement happens only in the job (JOB-02). The 60 s job cadence becomes every 15 s while the market is open plus the pre-open burst. **[D6]** |

### 6.2 Snapshot economics

| ID | Rule |
|---|---|
| SCL-07 | A snapshot on a fill or deposit is **enqueued**, not computed in the order transaction. The order response never waits for it. (Fills still record exactly one snapshot, in the job, and PERF-04 keeps its meaning.) |
| SCL-08 | Retention: keep all snapshots for 7 days, then **one per hour** for 90 days, then **one per day** forever. A nightly `CompactSnapshotsJob` does this. The first and last snapshot of each day and every snapshot adjacent to a deposit or a reset are always kept so PERF-04 results are unchanged. |
| SCL-09 | `GET /portfolio/history` reads at most **600 points** per response (server-side downsampling by bucket, keeping first, last and extremes). Benchmark series use the same buckets. |
| SCL-10 | Hourly snapshots are taken only for accounts with a position in an open market or a recent change. An idle account gets none. The close snapshot (once per trading day) stays for everyone. |
| SCL-11 | Add the indexes the new paths need (covered by migrations and verified with `EXPLAIN` in a spec): `orders(account_id, status)`, `sessions(user_id, last_seen_at)`, `portfolio_snapshots(account_id, taken_at)` exists. |
| SCL-12 | Frontend polling is **adaptive**: 15 s while the user is on the screen, 60 s on a second tab or when idle for 2 minutes, and none when hidden (existing). Home loads **one** `GET /home` summary (portfolio, pending orders, watchlist quotes) instead of four requests. **[D5]** |
| SCL-13 | HTTP caching: market status, overview and candles send `Cache-Control: public, max-age=…` with ETags, so a CDN or browser serves repeats. Per-user endpoints send `private, no-store`. |

### 6.3 Calendar

| ID | Rule |
|---|---|
| CAL-06 | `MarketCalendar` data lives in a table (`market_days`: date, open_at, close_at, status) seeded for the next two years and **extended by a yearly job and a Rake task** from a documented source. |
| CAL-07 | The app raises an alert (OBS-05) when fewer than **90 days** of calendar remain, and `/up/deep` (OBS-06) reports it. A spec fixes `Clock` to 2027-10-01 and asserts the alert and that stocks still trade until the end of the covered range. |

---

## 7. Accounts, sessions and security (SES, SEC)

### 7.1 Sessions and account lifecycle

| ID | Rule |
|---|---|
| SES-01 | Session tokens are stored **hashed** (SHA-256 of the token) in `sessions.token_digest`. The cookie keeps the raw token. A migration moves existing sessions (users sign in again, which is acceptable). |
| SES-02 | A session has `expires_at` (30 days absolute) and `last_seen_at` (touched at most once per 10 minutes). It also expires after **14 days idle**. An expired session returns 401 and is deleted. |
| SES-03 | `PruneSessionsJob` (daily) deletes expired sessions and keeps the table small. |
| SES-04 | `GET /sessions` lists the user's active sessions (device, approximate time, current flag). `DELETE /sessions/:id` and `DELETE /sessions` (all others) end them. Changing the password ends all other sessions. |
| SES-05 | **Password reset**: `POST /password_reset` (always 202, same body and timing whether or not the email exists, rate-limited) emails a single-use token valid 30 minutes, stored hashed. `PATCH /password_reset/:token` sets a new password (AUTH-02 rules) and ends all sessions. |
| SES-06 | **Change password**: `PATCH /account/password` requires the current password. |
| SES-07 | **Email verification**: signup sends a link valid 24 h. Until verified, trading and deposits work but a banner shows and some features are limited **[D1]**: unverified accounts cannot be on the leaderboard (P2) and password reset only goes to the verified address. |
| SES-08 | **Delete my account**: `DELETE /account` with password confirmation and `{confirm: "DELETE"}`. It anonymises the user (email replaced by `deleted-<id>@invalid`, name cleared) and removes sessions and the watchlist. It keeps order, deposit and snapshot rows, which belong to the anonymised account, so no ledger evidence disappears. **[D2]** |
| SES-09 | **Reset keeps history**: `Accounts::Reset` stops hard-deleting. It marks the old orders, deposits and snapshots with a `period` (an integer, incremented per reset), and every query and `ledger:verify` scope to the **current period**. Old periods stay for audit. MON-05 and MON-06 are checked per period. |
| SES-10 | **Data export**: `GET /account/export` returns the user's own orders, deposits and positions as CSV or JSON (rate-limited, JSON by default). |

### 7.2 Security and abuse

| ID | Rule |
|---|---|
| SEC-01 | `config.action_dispatch.trusted_proxies` is set from `TRUSTED_PROXIES` so `request.remote_ip` is the real client behind the load balancer. A spec sends `X-Forwarded-For` through a trusted proxy and checks the rate-limit key. |
| SEC-02 | Per-user rate limits (not only per IP), in Rails `rate_limit`: orders 60/min, deposits 10/hour, `account/reset` 3/day, search and candles 120/min, everything else authenticated 600/min. Anonymous endpoints stay IP-limited. Over limit returns `429 rate_limited` with `Retry-After`. |
| SEC-03 | **Login throttling by email** as well as by IP (10 failures per hour per email, then a 15 minute lockout that returns the same message and timing as a wrong password, AUTH-03). Successful login does not reset the counter for other IPs. |
| SEC-04 | Deposit caps: $10M per deposit (existing) and **$50M per account per day**. Order caps: 20 waiting (existing) and **500 orders per account per day**. Limits return `validation_failed` with a clear message. They protect the database from a runaway client, not the user. |
| SEC-05 | **Authorization is checked by construction**: a spec iterates every route in `routes.rb`, signs in two users, and for each member route tries user B on user A's resource, expecting 404 (or 403). A new route without a test entry fails CI. This extends AUTH-07. |
| SEC-06 | `config.hosts` is set from `ALLOWED_HOSTS`. CORS is configured explicitly from `ALLOWED_ORIGINS` with `credentials: true` for the SPA origin only, or removed entirely when the SPA and API share an origin (recommended, §8 OPS-02). |
| SEC-07 | Security headers: a strict CSP (the SPA's own origin, no inline script except the existing theme snippet via nonce), `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`. |
| SEC-08 | All user-facing secrets (SMTP, error tracker, provider keys) come from credentials or environment variables. `config/master.key` is never in the image or the repo. A Brakeman and secret-scan step in CI enforces this. |
| SEC-09 | Audit log: a `audit_events` table records signups, logins (success and failure), password changes and resets, session revocations, account deletes, admin actions and resets with user, IP, user agent and time. Rows are append-only and kept 1 year. |

---

## 8. Deployment, observability and operations (OPS, OBS, DR, ADM, NTF)

### 8.1 Deployment (OPS)

| ID | Rule |
|---|---|
| OPS-01 | A production `Dockerfile` (multi-stage, non-root, no dev gems) builds the Rails image. The frontend builds to static files (`vite build`) and is served by a CDN or the proxy, never by the Vite dev server. |
| OPS-02 | **One origin**: the SPA and `/api` are served from the same host (proxy path routing). The `pb_session` cookie then stays `SameSite=Lax; Secure; HttpOnly` with no CORS. |
| OPS-03 | Three runtime roles from one image: `web` (Puma), `worker` (Solid Queue with the JOB-01 queues) and `release` (migrations and seeds, run once per deploy). Seeds are idempotent and **do not** call providers synchronously in production (the refresh job does). |
| OPS-04 | Managed Postgres 16 with **point-in-time recovery**, separate databases for primary, cache and queue (as today), connection pooling (PgBouncer or the host's pooler). The app uses `DATABASE_URL`. |
| OPS-05 | Sizing is documented and enforced: `RAILS_MAX_THREADS` x web processes + worker threads + 5 must be at most the pool limit. A boot check fails loudly if not. |
| OPS-06 | Deploys are zero-downtime (rolling), with a **post-deploy smoke test** (signup, deposit, buy, sell, delete on a dedicated test account) that fails the release and rolls back. Rollback is one command. |
| OPS-07 | Environments: `development`, `test`, `staging` (production-like, real providers with a low-rate budget), `production`. Staging runs the load test (SCL-01). |
| OPS-08 | The repo is a **git repository**, `config/master.key`, `log/`, `coverage/`, `tmp/` and `.env` are untracked and verified (`git ls-files` in a CI step), stray files (`*.bak`) are removed, and `.env.example` matches reality. (F22, F23) |

### 8.2 Observability (OBS)

| ID | Rule |
|---|---|
| OBS-01 | **Error tracking** (Sentry or equivalent) for web, worker and the SPA, with release tags and the request id. The generic `rescue_from StandardError` reports before it renders. User ids are sent, emails and request bodies are scrubbed. |
| OBS-02 | **Structured JSON logs** with `request_id`, `user_id` (not email), `account_id`, route, status, duration and job name. No money amounts or passwords. |
| OBS-03 | **Metrics**: request rate, latency (p50/p95/p99), and 5xx by route; job queue depth, oldest-job age and failures by queue; provider calls, errors, latency and breaker state per provider; quote age (max and p95 across held assets); orders placed, filled, rejected and queued; snapshot rows added per day; DB pool usage. |
| OBS-04 | **Alerts** (page): 5xx above 1% for 5 minutes, any queue's oldest job above 2 minutes, `critical` queue above 30 seconds, a provider breaker open for over 5 minutes, held-asset quote age above 10 minutes while the market is open, `ledger:verify` failing, database disk above 80%, certificate expiry within 14 days. |
| OBS-05 | **Alerts** (ticket): calendar coverage under 90 days (CAL-07), backup older than 26 hours, failed jobs above zero for a day. |
| OBS-06 | Health endpoints: `GET /up` (liveness, unchanged) and `GET /up/deep` (readiness): database reachable, queue lag within limit, last successful quote refresh within 5 minutes, calendar coverage. Deep health returns 503 with a reason list. Load balancers use `/up`, monitors use `/up/deep`. |
| OBS-07 | A **status page** or at least a public `/status` JSON shows provider health, so "trading paused" (price_unavailable) is explainable to users. |

### 8.3 Disaster recovery, admin and notifications

| ID | Rule |
|---|---|
| DR-01 | Backups: daily snapshot plus continuous WAL (OPS-04), retained 14 days. A **restore drill** runs monthly into staging and runs `ledger:verify` against the restored data. |
| DR-02 | `ledger:verify` runs **hourly in production** (read-only, off the web path, `low` queue). A mismatch pages (OBS-04). Output includes the account id and rule, never balances in logs. |
| DR-03 | RPO 5 minutes, RTO 1 hour for the database. A written runbook (`docs/runbook.md`) lists restore, rollback, provider-outage and queue-stuck procedures. |
| ADM-01 | An `admin` boolean on users (set only from the console or a Rake task). Admin endpoints live under `/api/v1/admin` and require `admin` **and** a recent re-authentication (password within 15 minutes). Every admin action writes an audit event (SEC-09). |
| ADM-02 | Admin can: look up a user by email or id, see their account, positions, orders and sessions, revoke sessions, disable or re-enable a user (a disabled user gets 403 `account_disabled`), and trigger a password reset. Admin **cannot** edit balances or orders. Corrections happen through a documented, audited adjustment record **[D8]**. |
| ADM-03 | Admin can enable or disable an asset (`assets.active`) and see its quote age and provider errors. Disabling an asset with open positions keeps positions and allows sells but blocks buys. |
| ADM-04 | Admin sees failed jobs and can retry or discard them, and sees the queue depth per queue. |
| ADM-05 | A kill switch `trading_enabled` (a database setting, no deploy needed) blocks new orders and fills with `503 trading_paused` and a banner, for incidents and provider outages. Cancelling and reading still work. |
| NTF-01 | **Email** (transactional only): verification, password reset, password changed, queued order **filled** or **rejected**. Sent from a job with retry, one template per type, unsubscribe is not offered for security mail. |
| NTF-02 | Per-user preferences for order emails (default on for rejected, off for filled) in Settings. A queued order that fills at the open is also shown on Home as a notification the next time the user opens the app. |
| NTF-03 | No push, no SMS, no marketing email in v4. |

---

## 9. Delivery plan

Each phase ends with a deployable, tested state. IDs in brackets are the rules the phase must make pass.

| Phase | Content | Exit criteria |
|---|---|---|
| **P0.0 Foundation** (about 3 days) | `git init`, clean tree and `.env.example` (OPS-08), root CI, production Dockerfile and static frontend (OPS-01/02), `config.hosts` and CORS decision (SEC-06), error tracking and structured logs (OBS-01/02), set `trusted_proxies` (SEC-01). | A tagged image deploys to staging from CI, serves the SPA and API on one origin, and an injected exception appears in the tracker. |
| **P0.1 Provider isolation** (about 1 week) | MKD-01..07, the e2e scripted provider from v2 D5, provider contract specs, MKD metrics (OBS-03). | The 20-parallel-requests spec makes one provider call, an order with a stale quote returns `price_unavailable` without calling out, and breaker behaviour is tested. |
| **P0.2 Jobs** (about 1 week) | JOB-01..06, CAL-06/07, SCL-07 (async snapshots), queue and job alerts. | SCL-02 passes in staging with 500 queued orders and `ledger:verify` is clean. |
| **P0.3 Sessions and accounts** (about 1 week) | SES-01..10, SEC-02..05, SEC-09, NTF-01 (mail only). | Cross-user generated spec (SEC-05) green, password reset works end to end in staging, a replayed old cookie returns 401. |
| **P1.0 Scale** (about 1 week) | SCL-08..13, `GET /home`, adaptive polling, load test harness (k6) in the repo, a baseline report. | SCL-01, 03, 04, 06 pass at 200 concurrent users in staging, report committed to `docs/perf/`. |
| **P1.1 Operate** (about 1 week) | ADM-01..05, OBS-03..07, DR-01..03, runbook, kill switch drill. | Restore drill completed and documented, an on-call can pause trading from the admin UI, alerts fire in a game-day test. |
| **P2** (optional) | Leaderboard (LDR), licensed feed swap (MKD-08), more benchmarks. | Decided after P1.1. |

Total for P0 and P1: about **5 to 6 weeks** for one engineer (*estimate*). P0 alone is the minimum to invite outside users.

Order matters: P0.0 comes first because nothing else can be tested in a real environment without it. P0.1 comes before P0.2 because fills need trustworthy prices before they are fanned out.

---

## 10. Test strategy

Everything in §5 to §8 is a rule with an ID, and every ID needs a test that cites it (`it "... [MKD-02]"`).

1. **Update `script/rule_coverage`.** Its regexes list prefixes explicitly. Add `MKD`, `JOB`, `SCL`, `SES`, `SEC`, `OPS`, `OBS`, `DR`, `ADM`, `NTF`, `LDR`, and a third source file `docs/PRD-v4-multi-user.md` that uses the table format of v2 (`| ID | Rule |`). Rules that are verified outside RSpec (OPS-01, OPS-06, DR-01) cite a CI job or a runbook test name and the script scans `.github/workflows` and `docs/runbook.md` too.
2. **Unit and request specs** for each rule, in the style of the existing suite (`orders_place_spec.rb`, `concurrency_spec.rb`).
3. **Concurrency specs** for MKD-02 (20 threads, one provider call), JOB-02 (two fill jobs for one account), SES-02 (expiry boundary with `Clock`), and SEC-02 (limits per user across IPs).
4. **Property-style ledger test**: random mixes of buys, sells, deposits, resets (with periods, SES-09), splits and cancels run with 8 threads, then `Ledger::Verify` must be empty (SCL-06).
5. **Load test** (k6, in `loadtest/`): scenarios `browse`, `trade`, `open-burst`. It signs up its own users against staging with a scripted provider (never real providers). Thresholds from §3 are the pass criteria.
6. **Chaos checks** in staging: kill the worker, kill Postgres failover, return 500 from the provider for 10 minutes, set the clock 90 days before the calendar ends. Each has an expected result in the runbook.
7. **E2E (Playwright)** for the v2 flows still missing, plus: password reset, session list and revoke, email verification banner, kill switch banner, stale quote "Delayed" tag. Run at 375 and 1360 px with axe, as UX-08 requires.
8. **Gates in CI**: RuboCop, Brakeman, bundler-audit, `tsc`, `check:api`, rule coverage, SimpleCov thresholds (the v2 D7 numbers, finally enforced), and a `git ls-files` secret check (OPS-08).

---

## 11. Decisions to make together

| # | Question | Recommendation |
|---|---|---|
| D1 | Require **email verification** before trading? | No. Allow trading, show a banner, and gate only public features (leaderboard) and password reset on a verified email. Friction before first trade hurts a practice product. |
| D2 | **Delete account**: erase rows or anonymise? | Anonymise and keep ledger rows. Erasing orders breaks `ledger:verify` and the audit trail, and an anonymised account holds no personal data. Check this against your privacy policy and the laws that apply to your users. |
| D3 | Replace Yahoo/CoinGecko with a **licensed feed** now? | Not for the closed beta, if usage stays inside the gateway budgets (MKD-06). Required before any public launch. The interface in MKD-08 keeps the swap cheap, and the decision date is the end of P1.0 once real call counts are known. |
| D4 | Build a **leaderboard**? | Not in P0/P1. It is the most visible multi-user feature but it needs verified emails, display names, anti-cheat (deposits and resets distort returns) and a precomputed table. Do it as P2 with time-weighted return only. |
| D5 | One **`GET /home`** summary endpoint versus keeping four queries? | Add the summary. It cuts Home polling by roughly 3/4 and keeps the old endpoints for the other screens. |
| D6 | Stop **settling queued orders on reads** (JOB-06)? | Yes. A GET with writes makes load unpredictable. The cost is up to 15 s before a fill shows. The job runs every 15 s while the market is open, and the pre-open job covers the burst. |
| D7 | Hosting target (single VM with Docker, Fly.io, Render, Kamal, Kubernetes)? | Start with the simplest host that gives managed Postgres with PITR, a release step and rolling deploys. Do not adopt Kubernetes for 200 concurrent users. This decision does not change any rule here. |
| D8 | How does support correct a user's money? | Never by editing rows. Add a signed, audited `adjustment` ledger entry type (admin plus a second admin approval) only if a real need appears. For a practice product, resetting the account (SES-09) is the supported fix. |
| D9 | Free-tier provider limits: accept `price_unavailable` during throttling, or buy a paid CoinGecko key? | Buy the lowest paid CoinGecko tier before the beta. It costs little and removes the most likely cause of "trading paused". |
| D10 | Keep `STARTING_CASH` free deposits unlimited (SEC-04 caps only)? | Yes for now. Deposits are virtual and exist to let users experiment. Revisit if they distort any future leaderboard. |

---

## 12. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Yahoo blocks or throttles the app under production traffic. | Quotes go stale, trading pauses for everyone. | MKD-06 breaker and budgets, kill switch (ADM-05), "Delayed" UX (UX-05), a staged move to a licensed feed (D3). |
| Retention (SCL-08) deletes data PERF-04 needs, changing historical returns. | Wrong return numbers. | Keep boundary snapshots, run a before/after equality spec on a seeded history, and ship behind a dry-run flag first. |
| Moving settlement off the read path (JOB-06) delays fills visibly. | Users think orders are stuck. | 15 s cadence, the pre-open job, and a "queued, fills at the open" message already in UX-04. |
| Session hashing and the `period` migration (SES-01, SES-09) touch live data. | Lockout or wrong ledger. | Expand-then-contract migrations, a staging rehearsal on a copy of production data, and `ledger:verify` before and after. |
| Scope growth into product features. | The beta slips. | P2 stays P2. A new feature needs its own PRD. |
| Solid Queue, Solid Cache and data on one Postgres. | Queue load slows the ledger. | Separate databases (already), monitor pool usage (OBS-03), move queue to its own instance if the metric shows contention. |

---

## 13. Out of scope for v4

Real money, brokerage integrations, limit and stop orders, fees and slippage, fractional-share rules, dividends (v2 D3), extended hours (v2 D8), mobile apps, social features, multi-currency, localisation, and marketing pages.

---

## 14. Open items to confirm before work starts

1. Launch target: closed beta size and date (this PRD assumes 1,000 users, 200 concurrent).
2. Where it will be hosted (D7), who is on call, and whether a staging environment is acceptable.
3. An email sender (domain and provider) for NTF-01 and SES-05.
4. Privacy and terms: who owns them, and whether D2 matches them.
