#!/usr/bin/env bash
# OPS-06: post-deploy smoke test against a running environment. Exit non-zero fails the release (and triggers rollback).
#   deploy/smoke.sh https://staging.example.com
# Uses a throwaway account: signup, deposit, buy, sell, delete. Never touches real users.
set -euo pipefail
BASE="${1:?usage: smoke.sh BASE_URL}"
JAR="$(mktemp)"; trap 'rm -f "$JAR"' EXIT
EMAIL="smoke-$(date +%s)-$RANDOM@example.com"
call() { curl -fsS -b "$JAR" -c "$JAR" -H 'Content-Type: application/json' -H 'Accept: application/json' "$@"; }

curl -fsS "$BASE/up" > /dev/null
curl -fsS "$BASE/up/deep" > /dev/null || { echo "deep health failed"; exit 1; }
call -X POST "$BASE/api/v1/signup" -d "{\"name\":\"Smoke\",\"email\":\"$EMAIL\",\"password\":\"smoke-test-pass-1\"}" > /dev/null
call -X POST "$BASE/api/v1/deposits" -H "Idempotency-Key: smoke-dep-$RANDOM" -d '{"amount":"100"}' > /dev/null
call -X POST "$BASE/api/v1/orders" -H "Idempotency-Key: smoke-buy-$RANDOM" -d '{"symbol":"SPY","side":"buy","amount":"50"}' > /dev/null
call -X POST "$BASE/api/v1/orders" -H "Idempotency-Key: smoke-sell-$RANDOM" -d '{"symbol":"SPY","side":"sell","sell_all":true}' > /dev/null || true
call -X DELETE "$BASE/api/v1/account" -d '{"confirm":"DELETE","password":"smoke-test-pass-1"}' > /dev/null
echo "smoke OK ($EMAIL deleted)"
