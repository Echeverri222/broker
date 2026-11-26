# Load test (SCL-01..06)

`k6 run loadtest/scenario.js -e BASE_URL=https://staging.example.com -e USERS=1000`

Run it against **staging** (OPS-07), never production. It signs up its own throwaway users (`loadtest-*@example.com`),
holds 200 concurrent virtual users polling like open tabs (SCL-01, SCL-12), and places orders at 50 per minute with a
5-minute ramp to 200 per minute. The thresholds in the script are the pass criteria:

| Rule | Threshold |
|---|---|
| SCL-03 | p95 of reads under 150 ms, `POST /orders` under 400 ms, `GET /portfolio/history` under 300 ms |
| SCL-04 | fewer than 0.1% failed requests |
| SCL-02 | after the run, the admin queues page (`GET /api/v1/admin/queues`) shows no order pending past 60 s of the open |
| SCL-05 | `broker_provider_calls_this_minute` stays flat as users grow (check the dashboard during the run) |
| SCL-06 | `bin/rails ledger:verify` prints OK afterwards. A mismatch fails the run |

After the run, delete the test users: `bin/rails runner 'User.where("email LIKE ?", "loadtest-%").find_each(&:anonymise!)'`.
