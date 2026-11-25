require "rails_helper"

# PRD v4 §6 (JOB): queues, per-account fan-out, idempotency, no writes on reads.
RSpec.describe "Jobs [JOB]" do
  let(:closed) { Time.utc(2026, 3, 7, 16, 0, 0) }  # Saturday
  let(:open_t) { Time.utc(2026, 3, 9, 14, 0, 0) }  # Monday 10:00 ET
  def at(t) = Clock.override = -> { t }

  def open!
    at(open_t)
    Quote.update_all(as_of: open_t, fetched_at: open_t)
  end

  def queue(account, sym: "AAPL", amount: "100", key: "k#{SecureRandom.hex(3)}")
    Orders::Place.call(account: account, symbol: sym, side: "buy", amount: amount, idempotency_key: key).order
  end

  describe "queues and workers [JOB-01, JOB-05]" do
    let(:cfg) { YAML.safe_load(ERB.new(File.read(Rails.root.join("config/queue.yml"))).result, aliases: true)["production"] }

    it "has dedicated workers for critical, default and low" do
      queues = cfg["workers"].map { |w| w["queues"] }
      expect(queues).to eq(%w[critical default low])
    end

    it "keeps fills on the critical queue and slow jobs on low [JOB-01]" do
      expect([ FillPendingOrdersJob, FillAccountOrdersJob, RefreshAssetJob, PreOpenRefreshJob ].map { |j| j.new.queue_name }.uniq).to eq([ "critical" ])
      expect([ WarmMarketDataJob, LedgerVerifyJob, PruneSessionsJob ].map { |j| j.new.queue_name }.uniq).to eq([ "low" ])
      expect([ RefreshQuotesJob, SnapshotsJob, SnapshotAccountJob, SplitsJob ].map { |j| j.new.queue_name }.uniq).to eq([ "default" ])
    end

    it "takes thread counts from the environment [JOB-05]" do
      old = ENV["JOB_CRITICAL_THREADS"]
      ENV["JOB_CRITICAL_THREADS"] = "7"
      parsed = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/queue.yml"))).result, aliases: true)["production"]
      expect(parsed["workers"].first["threads"]).to eq(7)
    ensure
      ENV["JOB_CRITICAL_THREADS"] = old
    end
  end

  describe "FillPendingOrdersJob fans out per account [JOB-02]" do
    let(:users) { Array.new(3) { create(:user) } }

    before do
      at(closed)
      with_asset(symbol: "AAPL", price: "100")
      with_asset(symbol: "MSFT", price: "100")
    end

    it "enqueues one job per account that has waiting orders, not one per order" do
      queue(users[0].account); queue(users[0].account, sym: "MSFT", key: "second"); queue(users[1].account)
      open!
      expect { expect(FillPendingOrdersJob.perform_now).to eq(2) }
        .to have_enqueued_job(FillAccountOrdersJob).exactly(2).times
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |j| j["arguments"] }.flatten).to contain_exactly(users[0].account.id, users[1].account.id)
    end

    it "does nothing while the market is closed" do
      queue(users[0].account)
      expect { expect(FillPendingOrdersJob.perform_now).to eq(0) }.not_to have_enqueued_job(FillAccountOrdersJob)
    end

    it "fills one account's orders and leaves the others untouched [JOB-02]" do
      a = queue(users[0].account); b = queue(users[1].account)
      open!
      FillAccountOrdersJob.perform_now(users[0].account.id)
      expect(a.reload.status).to eq("filled")
      expect(b.reload.status).to eq("pending")
    end

    it "is idempotent: running the same account job twice fills once [JOB-04]" do
      o = queue(users[0].account)
      open!
      2.times { FillAccountOrdersJob.perform_now(users[0].account.id) }
      expect(o.reload.status).to eq("filled")
      expect(users[0].account.reload.cash).to eq(99_900)
      expect(Ledger::Verify.call).to be_empty
    end

    it "ignores an account that no longer exists [JOB-04]" do
      expect { FillAccountOrdersJob.perform_now(0) }.not_to raise_error
    end

    it "is scheduled every 15 seconds [JOB-02]" do
      yml = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result, aliases: true)
      expect(yml["production"]["fill_pending_orders"]).to include("class" => "FillPendingOrdersJob", "schedule" => "every 15 seconds")
    end
  end

  describe "settlement is not done by reads [JOB-06]" do
    include ApiHelpers
    let(:session) { ActionDispatch::Integration::Session.new(Rails.application) }

    it "GET /portfolio and GET /orders leave a waiting order pending even when the market is open" do
      user = create(:user)
      at(closed)
      with_asset(symbol: "AAPL", price: "100")
      order = queue(user.account)
      open!
      session.post "/api/v1/session", params: { email: user.email, password: "password123" }.to_json, headers: ApiHelpers::JSON_HEADERS
      session.get "/api/v1/portfolio", headers: ApiHelpers::JSON_HEADERS
      session.get "/api/v1/orders", headers: ApiHelpers::JSON_HEADERS
      expect(order.reload.status).to eq("pending")
      FillAccountOrdersJob.perform_now(user.account.id)
      expect(order.reload.status).to eq("filled")
    end
  end

  describe "snapshots fan out per account [JOB-03]" do
    before { with_asset(symbol: "AAPL", price: "100"); with_asset(symbol: "BTC", kind: "crypto", price: "100") }

    it "enqueues one SnapshotAccountJob per eligible account, with one shared timestamp" do
      holder = create(:user); idle = create(:user)
      at(open_t); Quote.update_all(as_of: open_t, fetched_at: open_t)
      Orders::Place.call(account: holder.account, symbol: "AAPL", side: "buy", amount: "100", idempotency_key: "h1")
      expect { expect(SnapshotsJob.perform_now("hourly")).to eq(1) }.to have_enqueued_job(SnapshotAccountJob).once
      args = ActiveJob::Base.queue_adapter.enqueued_jobs.last["arguments"]
      expect(args.first).to eq(holder.account.id)
      expect(idle.account.portfolio_snapshots.count).to eq(1) # only the signup snapshot
    end

    it "records the snapshot when the job runs [JOB-03]" do
      user = create(:user); at(open_t)
      expect { SnapshotAccountJob.perform_now(user.account.id, open_t.utc.iso8601(6), "hourly") }
        .to change { user.account.portfolio_snapshots.count }.by(1)
    end

    it "keeps one close snapshot per account per day even if the job runs twice [PERF-05, JOB-04]" do
      user = create(:user); at(Time.utc(2026, 3, 9, 20, 10)) # 16:10 ET Monday
      2.times { SnapshotAccountJob.perform_now(user.account.id, Clock.now.utc.iso8601(6), "close") }
      expect(user.account.portfolio_snapshots.where("taken_at >= ?", Clock.now - 1.hour).count).to eq(1)
    end

    it "enqueues close snapshots for everyone on a trading day, none on a holiday [JOB-03, PERF-05]" do
      create(:user); create(:user)
      at(Time.utc(2026, 3, 9, 20, 10))
      expect(Snapshots::RecordAll.enqueue(kind: :close)).to eq(2)
      at(Time.utc(2026, 3, 8, 20, 10)) # Sunday
      expect(Snapshots::RecordAll.enqueue(kind: :close)).to eq(0)
    end
  end

  describe "retries [JOB-04]" do
    it "retries deadlocks and provider errors with a bounded number of attempts" do
      handlers = ApplicationJob.rescue_handlers.map(&:first)
      expect(handlers).to include("ActiveRecord::Deadlocked", "MarketData::ProviderError", "ActiveRecord::LockWaitTimeout")
    end
  end

  describe "LedgerVerifyJob [DR-02]" do
    it "returns 0 for a clean ledger and does not report" do
      create(:user)
      expect(Rails.error).not_to receive(:report)
      expect(LedgerVerifyJob.perform_now).to eq(0)
    end

    it "reports a mismatch without logging balances" do
      user = create(:user)
      user.account.update_columns(cash: 5)
      logged = []
      allow(Rails.logger).to receive(:error) { |m| logged << m }
      expect(Rails.error).to receive(:report).with(an_instance_of(RuntimeError), hash_including(severity: :error))
      expect(LedgerVerifyJob.perform_now).to eq(1)
      expect(logged.join).to include("account=#{user.account.id} rule=MON-05")
      expect(logged.join).not_to match(/100000|\b5\.0\b/)
    end

    it "is scheduled hourly on the low queue" do
      yml = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result, aliases: true)
      expect(yml["production"]["ledger_verify"]).to include("class" => "LedgerVerifyJob")
    end
  end
end
