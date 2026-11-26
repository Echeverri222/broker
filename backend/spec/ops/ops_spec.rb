require "rails_helper"
require Rails.root.join("config/json_log_formatter")

# PRD v4 §10-12: operability. Infrastructure files are tested for the properties the PRD promises, because a
# Dockerfile that quietly copies master.key, or an alert list that lost a rule, is a regression like any other.
RSpec.describe "Operations [OPS, OBS, SEC-08, DR, SCL]" do
  ROOT = Rails.root.join("..").freeze

  def read(path) = File.read(ROOT.join(path))

  describe "production image and one origin [OPS-01, OPS-02, OPS-03]" do
    it "builds a multi-stage, non-root Rails image without dev gems or the master key" do
      docker = read("backend/Dockerfile")
      expect(docker.scan(/^FROM /).size).to be >= 2
      expect(docker).to match(/BUNDLE_WITHOUT="development:test"/)
      expect(docker).to match(/^USER 1000/)
      expect(read("backend/.dockerignore")).to include("config/master.key", ".env")
    end

    it "serves the SPA as static files and proxies /api on the same origin" do
      expect(read("frontend/Dockerfile")).to match(/npm run build/).and match(/nginx/)
      conf = read("deploy/nginx.conf")
      expect(conf).to include("location /api/", "proxy_pass ${API_UPSTREAM}", "X-Forwarded-For", "Content-Security-Policy")
      expect(conf).not_to match(/Access-Control-Allow-Origin/)
    end

    it "runs web, worker and release from one image, with release finishing first" do
      compose = YAML.load_file(ROOT.join("deploy/compose.prod.yml"), aliases: true)
      services = compose["services"]
      expect(services.keys).to include("web", "worker", "release", "proxy", "db")
      expect(services["worker"]["command"]).to eq("bin/jobs")
      expect(services["release"]["command"]).to eq("bin/release")
      expect(services["web"]["depends_on"]["release"]["condition"]).to eq("service_completed_successfully")
      expect(services.values_at("web", "worker", "release").map { |s| s["build"]["context"] }.uniq.size).to eq(1)
    end

    it "makes the release step idempotent and free of provider calls" do
      release = read("backend/bin/release")
      expect(release).to include("db:prepare", "db:seed")
      expect(File.executable?(ROOT.join("backend/bin/release"))).to be(true)
      seeds = read("backend/db/seeds.rb")
      expect(seeds).to match(/find_or_(create|initialize)_by|upsert/)
      production_part = seeds.split(/^if /).first # everything before the non-production guard
      expect(production_part).not_to match(/Quotes::Refresh|YahooProvider|Warm\.call/) # MKD-04: the refresh job fills quotes
      expect(seeds).to match(/if !Rails\.env\.production\?.*\n\s+Quotes::Refresh/)
    end
  end

  describe "database and pool [OPS-04, OPS-05]" do
    it "reads one URL per database so cache and queue can be separate instances" do
      cfg = ERB.new(read("backend/config/database.yml")).result
      prod = YAML.safe_load(cfg, aliases: true)["production"]
      expect(prod.keys).to contain_exactly("primary", "cache", "queue")
      expect(read("backend/config/database.yml")).to include("DATABASE_URL", "CACHE_DATABASE_URL", "QUEUE_DATABASE_URL")
    end

    it "refuses to boot when threads and workers exceed the pool limit" do
      env = { "DB_POOL_LIMIT" => "20", "WEB_PROCESSES" => "2", "RAILS_MAX_THREADS" => "3" }
      # web 2 x 3 = 6, worker 2 + 3 + 1 + 1 dispatcher = 7, plus 5 spare = 18
      expect(DeployConfig.pool_problem(env)).to eq("database pool: need 18 connections (web 6 + worker 7 + 5) but DB_POOL_LIMIT is 20").or be_nil
      expect(DeployConfig.pool_problem(env.merge("DB_POOL_LIMIT" => "17"))).to eq("database pool: need 18 connections (web 6 + worker 7 + 5) but DB_POOL_LIMIT is 17")
      expect(DeployConfig.pool_problem(env.merge("DB_POOL_LIMIT" => "18"))).to be_nil
      expect(DeployConfig.pool_problem({})).to be_nil
    end

    it "counts worker threads from the same variables the queue config uses" do
      env = { "DB_POOL_LIMIT" => "40", "WEB_PROCESSES" => "1", "RAILS_MAX_THREADS" => "3", "JOB_DEFAULT_THREADS" => "10", "JOB_CONCURRENCY" => "2" }
      # web 3, worker 2 + 10 x 2 + 1 + 1 = 24, plus 5 = 32
      expect(DeployConfig.pool_problem(env)).to be_nil
      expect(DeployConfig.pool_problem(env.merge("DB_POOL_LIMIT" => "31"))).to match(/need 32 connections/)
    end

    it "boots production with the check wired in" do
      expect(read("backend/config/initializers/pool_check.rb")).to include("DeployConfig.pool_problem")
    end
  end

  describe "post-deploy smoke and environments [OPS-06, OPS-07]" do
    it "ships a smoke script that exercises signup, deposit, buy, sell and delete and fails on error" do
      script = read("deploy/smoke.sh")
      expect(script).to include("set -euo pipefail")
      %w[signup deposits orders account].each { |step| expect(script).to include("/api/v1/#{step}") }
      expect(File.executable?(ROOT.join("deploy/smoke.sh"))).to be(true)
    end

    it "documents deploy, rollback and the four environments" do
      rb = read("docs/runbook.md")
      expect(rb).to match(/roll back/i).and include("deploy/smoke.sh", "bin/release")
      expect(read("loadtest/README.md")).to match(/staging/i)
    end
  end

  describe "repository hygiene [OPS-08, SEC-08]" do
    it "does not track secrets, logs, coverage or backups" do
      tracked = `git -C #{ROOT} ls-files 2>/dev/null`.split("\n")
      skip "not a git checkout" if tracked.empty?
      expect(tracked.grep(%r{(^|/)master\.key$|(^|/)\.env$|(^|/)log/.+\.log$|(^|/)coverage/|(^|/)tmp/(?!\.keep$)|\.bak$})).to eq([])
    end

    it "ignores the same things in git and in the image" do
      ignore = read(".gitignore") + read("backend/.gitignore")
      expect(ignore).to include("master.key", ".env", "coverage", "node_modules")
    end

    it "keeps .env.example in line with the variables the app reads" do
      example = read(".env.example")
      %w[SECRET_KEY_BASE DATABASE_URL ALLOWED_HOSTS ALLOWED_ORIGINS TRUSTED_PROXIES APP_URL SMTP_ADDRESS METRICS_TOKEN COINGECKO_API_KEY].each do |var|
        expect(example).to include(var)
      end
      expect(example).not_to match(/FINNHUB|TWELVE_DATA/) # providers that were never implemented
    end

    it "runs Brakeman, bundler-audit and a secret scan in CI" do
      ci = read(".github/workflows/ci.yml")
      expect(ci).to include("brakeman", "bundler-audit", "gitleaks", "git ls-files")
    end

    it "reads every runtime secret from the environment" do
      cfg = read("backend/config/environments/production.rb")
      expect(cfg).to include('ENV["SMTP_PASSWORD"]')
      expect(cfg).not_to match(/password:\s*["'][^"']+["']/)
    end
  end

  describe "metrics, alerts and status [OBS-03, OBS-04, OBS-05, OBS-07]" do
    def metrics(token = "s3cret", header: "Bearer s3cret")
      ENV["METRICS_TOKEN"] = token
      yield header
    ensure
      ENV.delete("METRICS_TOKEN")
    end
  end

  describe "alert rules [OBS-04, OBS-05]" do
    let(:rules) { YAML.load_file(ROOT.join("deploy/alerts.yml"))["groups"].first["rules"].to_h { |r| [ r["alert"], r ] } }

    it "pages on the conditions the PRD lists" do
      page = rules.select { |_, r| r["labels"]["severity"] == "page" }.keys
      expect(page).to include("High5xxRate", "QueueLagging", "CriticalQueueLagging", "ProviderCircuitOpen", "HeldQuotesStaleWhileOpen",
                              "LedgerVerifyFailing", "DatabaseDiskHigh", "CertificateExpiring")
      expect(rules["High5xxRate"]["expr"]).to include("0.01")
      expect(rules["CriticalQueueLagging"]["expr"]).to include("> 30")
      expect(rules["QueueLagging"]["expr"]).to include("> 120")
      expect(rules["HeldQuotesStaleWhileOpen"]["expr"]).to include("> 600")
    end

    it "opens tickets for slow-burn conditions" do
      ticket = rules.select { |_, r| r["labels"]["severity"] == "ticket" }.keys
      expect(ticket).to include("CalendarCoverageLow", "BackupTooOld", "FailedJobsForADay")
      expect(rules["CalendarCoverageLow"]["expr"]).to include("< 90")
      expect(rules["BackupTooOld"]["expr"]).to include("26 * 3600")
    end

    it "only uses metrics the app exports (or standard exporters)" do
      exported = MetricsController.new.send(:lines).join("\n") rescue ""
      expect(exported).to include("broker_queue_oldest_ready_seconds", "broker_provider_circuit_open", "broker_calendar_days_remaining")
      ours = rules.values.flat_map { |r| r["expr"].scan(/broker_\w+/) }.uniq
      ours.each { |m| expect(exported).to include(m), "alert uses #{m}, which /metrics does not export" }
    end
  end

  describe "metrics endpoint [OBS-03]", type: :request do
    around do |ex|
      ENV["METRICS_TOKEN"] = "s3cret"
      ex.run
      ENV.delete("METRICS_TOKEN")
    end

    it "is hidden without the right token and off when none is configured" do
      get "/metrics"
      expect(response).to have_http_status(:not_found)
      get "/metrics", headers: { "Authorization" => "Bearer wrong" }
      expect(response).to have_http_status(:not_found)
      ENV["METRICS_TOKEN"] = ""
      get "/metrics", headers: { "Authorization" => "Bearer " }
      expect(response).to have_http_status(:not_found)
    end

    it "exports counts and ages in Prometheus format, and no user data" do
      user = create(:user, email: "metrics-user@example.com")
      with_asset(symbol: "AAPL", price: "100")
      get "/metrics", headers: { "Authorization" => "Bearer s3cret" }
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with("text/plain")
      expect(response.body).to match(/^broker_users_total 1$/)
      expect(response.body).to match(/^broker_provider_circuit_open\{provider="yahoo"\} 0$/)
      expect(response.body).to match(/^broker_trading_enabled 1$/)
      expect(response.body).not_to include(user.email)
      expect(response.body).not_to match(/cash|password/i)
    end

    it "reflects the breaker, the kill switch and the last ledger check" do
      MarketData::Gateway::FAILURE_LIMIT.times { MarketData::Gateway.call("yahoo") { raise MarketData::ProviderError, "x" } rescue nil }
      Setting.set("trading_enabled", false)
      LedgerVerifyJob.perform_now
      get "/metrics", headers: { "Authorization" => "Bearer s3cret" }
      expect(response.body).to include('broker_provider_circuit_open{provider="yahoo"} 1', "broker_trading_enabled 0", "broker_ledger_verify_problems 0")
    end
  end

  describe "public status [OBS-07]", type: :request do
    it "shows provider health and the trading switch with no session and no user data" do
      get "/api/v1/status", headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).to include("trading_enabled" => true, "degraded" => false)
      expect(body["providers"]).to eq("yahoo" => "closed", "coingecko" => "closed")
      Setting.set("trading_enabled", false)
      get "/api/v1/status", headers: { "Accept" => "application/json" }
      expect(JSON.parse(response.body)).to include("trading_enabled" => false, "degraded" => true)
    end
  end

  describe "structured logs and error reporting [OBS-01, OBS-02]" do
    it "writes one JSON object per line with level, time and request id" do
      out = StringIO.new
      logger = ActiveSupport::TaggedLogging.new(Logger.new(out))
      logger.formatter = JsonLogFormatter.new
      logger.tagged("req-123") { logger.info("hello") }
      line = JSON.parse(out.string)
      expect(line).to include("level" => "INFO", "message" => "hello", "request_id" => "req-123")
      expect(Time.iso8601(line["time"])).to be_a(Time)
    end

    it "scrubs secrets and email addresses from messages" do
      f = JsonLogFormatter.new
      line = JSON.parse(f.call("INFO", Time.now, nil, "login a@b.com password=hunter2 token=abc Authorization=xyz"))
      expect(line["message"]).to eq("login [email] password=[FILTERED] token=[FILTERED] Authorization=[FILTERED]")
    end

    it "formats exceptions without a backtrace dump and keeps single-line output" do
      line = JsonLogFormatter.new.call("ERROR", Time.now, nil, StandardError.new("bad\nthing"))
      expect(line.count("\n")).to eq(1)
      expect(JSON.parse(line)["message"]).to eq("StandardError: bad\nthing")
    end

    it "uses JSON logs in production" do
      expect(read("backend/config/environments/production.rb")).to include("JsonLogFormatter")
    end

    it "reports unexpected exceptions to subscribers with ids, never emails", type: :request do
      reports = []
      subscriber = Class.new { define_method(:report) { |error, **kw| reports << [ error, kw ] } }.new
      Rails.error.subscribe(subscriber)
      user = create(:user, email: "leak@example.com")
      allow_any_instance_of(Api::V1::MarketController).to receive(:status).and_raise(RuntimeError, "boom")
      post "/api/v1/session", params: { email: user.email, password: "password123" }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      get "/api/v1/market/status", headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(500)
      error, kw = reports.last
      expect(error.message).to eq("boom")
      expect(kw[:context]).to include(user_id: user.id, route: "GET /api/v1/market/status")
      expect(kw[:context].to_s).not_to include("leak@example.com")
    ensure
      Rails.error.unsubscribe(subscriber)
    end
  end

  describe "backups, restore and runbook [DR-01, DR-02, DR-03]" do
    it "documents restore, rollback, provider outage and queue procedures with the recovery targets" do
      rb = read("docs/runbook.md")
      expect(rb).to include("RPO 5 minutes, RTO 1 hour", "Restore the database", "Provider outage", "Queue stuck", "ledger:verify")
      expect(rb).to match(/14 days/)
    end

    it "runs the ledger check hourly on the low queue" do
      yml = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result, aliases: true)["production"]
      expect(yml["ledger_verify"]).to include("class" => "LedgerVerifyJob")
      expect(yml["ledger_verify"]["schedule"]).to match(/hour/)
      expect(LedgerVerifyJob.new.queue_name).to eq("low")
    end
  end

  describe "load test [SCL-01, SCL-02, SCL-03, SCL-04, SCL-05, SCL-06]" do
    let(:script) { read("loadtest/scenario.js") }

    it "encodes the PRD targets as thresholds" do
      expect(script).to include("rate<0.001", "p(95)<150", "p(95)<400", "p(95)<300")
      expect(script).to match(/vus: Math.min\(USERS, 200\)/)
      expect(script).to match(/target: 200, duration: "5m"/)
    end

    it "documents each rule's pass criterion and the ledger check afterwards" do
      readme = read("loadtest/README.md")
      %w[SCL-02 SCL-03 SCL-04 SCL-05 SCL-06].each { |id| expect(readme).to include(id) }
      expect(readme).to include("ledger:verify")
    end

    it "keeps provider calls constant in user count: one budget per provider, not per request [SCL-05]" do
      expect(MarketData::Gateway::DEFAULT_BUDGETS).to eq("yahoo" => 120, "coingecko" => 30)
      expect(read("docs/PRD-v4-multi-user.md")).to match(/SCL-05/)
    end
  end
end
