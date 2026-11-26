# Runbook

For whoever is on call. Targets (DR-03): database **RPO 5 minutes, RTO 1 hour**. Health: `GET /up` (liveness, for the load
balancer) and `GET /up/deep` (readiness with reasons, for monitors). Public status: `GET /api/v1/status`. Metrics: `GET
/metrics` with `Authorization: Bearer $METRICS_TOKEN`. Alert rules live in `deploy/alerts.yml`.

## Roles and deploys (OPS-03, OPS-06)
One image, three commands: `web` (`bin/rails server`), `worker` (`bin/jobs`), `release` (`bin/release`, once per deploy,
before web and worker start). Roll web and worker one by one. After a deploy run `deploy/smoke.sh https://<host>`: it signs
up a throwaway user, deposits, buys, sells and deletes the account. If it fails, **roll back** by redeploying the previous
image tag (migrations are additive, so the old code runs on the new schema).

## Pause trading (ADM-05)
Admin API: `PATCH /api/v1/admin/settings {"trading_enabled": false}` (needs an admin session re-authenticated in the last 15
minutes). New orders get `503 trading_paused`, waiting orders stay waiting, reading and cancelling keep working. Switch back
with `true`. Console fallback: `bin/rails runner 'Setting.set("trading_enabled", false)'`. Drill this quarterly.

## Provider outage (Yahoo or CoinGecko)
Symptom: `GET /api/v1/status` shows a provider `open`, `/up/deep` says `<provider> circuit open`, users see "Delayed".
1. The gateway already stopped calling the provider (circuit breaker, MKD-06) and orders on stale quotes return
   `price_unavailable`. Nothing is lost.
2. Watch `broker_provider_circuit_open`. The breaker probes again every 30 seconds.
3. If the outage passes 30 minutes during market hours, pause trading (above) so nobody is confused, and post on the status page.
4. If Yahoo is rate limiting us, lower `YAHOO_MAX_PER_MIN` (default 120) and redeploy. See D3 in the PRD about a licensed feed.

## Queue stuck or lagging
`GET /api/v1/admin/queues` shows depth per queue and failed jobs. `critical` must stay under 30 s of lag.
- Failed jobs: read the error, fix, `POST /api/v1/admin/jobs/:id/retry`, or `DELETE` to discard.
- No worker running: start `bin/jobs`. Jobs are idempotent (JOB-04), so a restart is always safe.
- Orders waiting after the open: `FillPendingOrdersJob` runs every 15 s. Run it by hand with
  `bin/rails runner 'FillPendingOrdersJob.perform_now'`.

## Restore the database (DR-01, DR-03)
Managed Postgres with point-in-time recovery (OPS-04). Daily snapshot plus WAL, kept 14 days.
1. Restore to a **new** instance at the wanted time (before the incident).
2. Point a staging release at it and run `bin/rails ledger:verify`. It must print OK before anything else.
3. Cut over by changing `DATABASE_URL`, `CACHE_DATABASE_URL` and `QUEUE_DATABASE_URL`, then run `deploy/smoke.sh`.
4. The restore drill runs monthly into staging with step 2 as the pass criterion. Record the date and the time it took here.

| Drill date | Restore time | `ledger:verify` | Notes |
|---|---|---|---|
| (first drill before launch) | | | |

## Ledger mismatch (DR-02)
`LedgerVerifyJob` runs hourly and pages on a mismatch. It reports the account id and the rule, never balances. Do not edit
balances by hand. Pause trading if more than one account is affected, then follow the adjustment process in PRD v4 D8.

## Calendar coverage (CAL-06, CAL-07)
A ticket opens when fewer than 90 days remain. Extend `MarketCalendar` (holidays and early closes from the NYSE schedule,
https://www.nyse.com/markets/hours-calendars), add the spec, deploy.

## Admin and users
Make an admin from the console only: `bin/rails runner 'User.find_by!(email: "...").update!(admin: true)'`. Disabled users
get `account_disabled` and are signed out. There is deliberately no way to edit balances or orders from the API.

## Secrets (SEC-08)
All secrets are environment variables: `SECRET_KEY_BASE`, `DATABASE_URL`, `CACHE_DATABASE_URL`, `QUEUE_DATABASE_URL`,
`SMTP_*`, `METRICS_TOKEN`, `COINGECKO_API_KEY`. `config/master.key` is never in the image or the repo. Rotate
`SECRET_KEY_BASE` only with a planned sign-out of all users (signed tokens become invalid).

## Sizing (OPS-05)
`WEB_PROCESSES x RAILS_MAX_THREADS + worker threads + 5` must be at most `DB_POOL_LIMIT`. The app refuses to boot otherwise.
Use a pooler (PgBouncer in transaction mode) when the limit is the managed database's connection cap.
