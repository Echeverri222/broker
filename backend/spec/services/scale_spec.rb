require "rails_helper"

# PRD v4 §8 (SCL): data growth, response size, indexes and caching. The numbers in the SCL-01..06 load targets are
# exercised by loadtest/ (see spec/ops); here we pin the code behaviour that makes them reachable.
RSpec.describe "Scale rules [SCL]" do
  before { Clock.override = -> { BrokerHelpers::OPEN_TIME } }

  def snap(account, at, value = 1000)
    PortfolioSnapshot.create!(account: account, total_value: value, cash: value, invested_value: 0, net_deposits: value, taken_at: at)
  end

  describe "snapshot retention [SCL-08]" do
    let(:account) { create(:user).account }
    let(:now) { Clock.now }

    before { account.portfolio_snapshots.delete_all }

    it "keeps everything from the last 7 days" do
      12.times { |i| snap(account, now - i.hours - 10.minutes) }
      expect { CompactSnapshotsJob.perform_now }.not_to change { account.portfolio_snapshots.count }
    end

    it "keeps one per hour (the last) between 7 and 90 days, plus the first and last of each day" do
      day = (now - 20.days).beginning_of_day
      times = (0..5).map { |i| day + 10.hours + (i * 10).minutes } + [ day + 23.hours + 50.minutes ] + [ day + 1.hour ]
      times.each { |t| snap(account, t) }
      expect(account.portfolio_snapshots.count).to eq(8)
      CompactSnapshotsJob.perform_now
      kept = account.portfolio_snapshots.order(:taken_at).pluck(:taken_at)
      expect(kept).to eq([ day + 1.hour, day + 10.hours + 50.minutes, day + 23.hours + 50.minutes ])
    end

    it "keeps one per day (plus first and last) after 90 days" do
      day = (now - 200.days).beginning_of_day
      [ 1, 5, 9, 13, 17, 21 ].each { |h| snap(account, day + h.hours) }
      CompactSnapshotsJob.perform_now
      expect(account.portfolio_snapshots.order(:taken_at).pluck(:taken_at)).to eq([ day + 1.hour, day + 21.hours ])
    end

    it "keeps the snapshots on either side of a deposit so range returns do not change [PERF-04]" do
      day = (now - 20.days).beginning_of_day
      [ 10, 11, 12, 13, 14 ].each { |h| snap(account, day + h.hours + 5.minutes) }
      snap(account, day + 10.hours + 30.minutes)
      account.deposits.create!(amount: 500, kind: "deposit", created_at: day + 10.hours + 40.minutes)
      range_before = Portfolios::History.call(account, range: "ALL")
      CompactSnapshotsJob.perform_now
      kept = PortfolioSnapshot.where(account_id: account.id).pluck(:taken_at) # (a loaded association would hide the deletes)
      expect(kept).to include(day + 10.hours + 30.minutes) # just before the deposit
      expect(kept).to include(day + 11.hours + 5.minutes)  # just after
      expect(Portfolios::History.call(account, range: "ALL").slice(:return, :deposits_in_range, :return_percent)).to eq(range_before.slice(:return, :deposits_in_range, :return_percent))
    end

    it "is idempotent and reports how many rows it removed" do
      day = (now - 20.days).beginning_of_day
      6.times { |i| snap(account, day + 10.hours + (i * 5).minutes) }
      first = CompactSnapshotsJob.perform_now
      expect(first).to be > 0
      expect(CompactSnapshotsJob.perform_now).to eq(0)
    end

    it "runs nightly on the low queue" do
      yml = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result, aliases: true)["production"]
      expect(yml["compact_snapshots"]).to include("class" => "CompactSnapshotsJob")
      expect(CompactSnapshotsJob.new.queue_name).to eq("low")
    end
  end

  describe "history size [SCL-09]" do
    it "returns the series untouched when it is short enough" do
      series = (1..600).map { |i| [ Time.at(i), BigDecimal(i) ] }
      expect(Portfolios::History.downsample(series, 600)).to eq(series)
    end

    it "caps the series at 600 points and keeps first, last and the extremes" do
      series = (1..5000).map { |i| [ Time.at(i), BigDecimal(i % 977) ] }
      series[2500] = [ Time.at(2501), BigDecimal(-50) ]
      series[3100] = [ Time.at(3101), BigDecimal(9999) ]
      out = Portfolios::History.downsample(series, 600)
      expect(out.size).to be <= 600
      expect(out.first).to eq(series.first)
      expect(out.last).to eq(series.last)
      expect(out.map(&:last)).to include(BigDecimal(-50), BigDecimal(9999))
      expect(out.map(&:first)).to eq(out.map(&:first).sort)
    end

    it "serves at most 600 points, and the benchmark uses the same times" do
      account = create(:user).account
      account.portfolio_snapshots.delete_all
      with_asset(symbol: "SPY", kind: "etf", price: "400")
      rows = (1..1500).map { |i| { account_id: account.id, total_value: 1000 + i, cash: 1000, invested_value: i, net_deposits: 1000, taken_at: Clock.now - i.minutes, created_at: Clock.now, updated_at: Clock.now } }
      PortfolioSnapshot.insert_all(rows)
      prices = (0..40).map { |d| [ (Clock.now - d.days).to_i, BigDecimal("400") ] }.reverse
      allow(MarketData).to receive(:history).and_return(prices)
      body = Portfolios::History.call(account, range: "ALL", benchmark: true)
      expect(body[:series].size).to be <= 600
      expect(body[:benchmark][:series].map { |p| p[:time] }).to eq(body[:series].map { |p| p[:time] })
      expect(body[:series].last[:time]).to eq(Fmt.iso(Clock.now))
    end
  end

  describe "snapshot eligibility [SCL-10]" do
    it "takes hourly snapshots only for accounts holding something tradable now, and a close snapshot for everyone" do
      with_asset(symbol: "AAPL", price: "100")
      holder, idle = create(:user), create(:user)
      Orders::Place.call(account: holder.account, symbol: "AAPL", side: "buy", amount: "100", idempotency_key: "s1")
      expect(Snapshots::RecordAll.enqueue(kind: :hourly)).to eq(1)

      Clock.override = -> { BrokerHelpers::OPEN_TIME + 10.hours } # market closed, equities only
      expect(Snapshots::RecordAll.enqueue(kind: :hourly)).to eq(0)

      Clock.override = -> { Time.utc(2026, 3, 2, 21, 5) } # just after the close on a trading day
      expect(Snapshots::RecordAll.enqueue(kind: :close)).to eq(Account.count)
      expect(idle.account.positions).to be_empty
    end
  end

  describe "indexes [SCL-11]" do
    def index?(table, cols) = ActiveRecord::Base.connection.indexes(table).any? { |i| i.columns == cols.map(&:to_s) }

    it "has the indexes the hot paths need" do
      expect(index?(:orders, %i[account_id status])).to be(true)
      expect(index?(:sessions, %i[user_id last_seen_at])).to be(true)
      expect(index?(:portfolio_snapshots, %i[account_id taken_at])).to be(true)
      expect(index?(:sessions, %i[token_digest])).to be(true)
    end

    it "uses them: the pending-orders and snapshot range queries do not scan the table" do
      conn = ActiveRecord::Base.connection
      conn.execute("SET enable_seqscan = off")
      plan = lambda { |sql| conn.select_values("EXPLAIN #{sql}").join("\n") }
      expect(plan.call("SELECT * FROM portfolio_snapshots WHERE account_id = 1 AND taken_at >= now() - interval '30 days' ORDER BY taken_at")).to match(/Index/)
      expect(plan.call("SELECT * FROM orders WHERE account_id = 1 AND status = 'pending'")).to match(/Index/)
      expect(plan.call("SELECT * FROM sessions WHERE user_id = 1 AND last_seen_at > now()")).to match(/Index/)
    ensure
      conn.execute("RESET enable_seqscan")
    end
  end

  describe "HTTP caching [SCL-13]", type: :request do
    it "lets shared caches keep market status, overview and candles, with ETags that give a 304" do
      sign_up!
      with_asset(symbol: "SPY", kind: "etf", price: "400")
      %w[/market/status /market/overview].each do |path|
        api(:get, path)
        expect(response.headers["Cache-Control"]).to include("public").and match(/max-age=\d+/)
        etag = response.headers["ETag"]
        expect(etag).to be_present
        get "/api/v1#{path}", headers: { "Accept" => "application/json", "If-None-Match" => etag }
        expect(response).to have_http_status(:not_modified)
      end
    end

    it "marks candles public and everything per-user private, no-store" do
      sign_up!
      with_asset(symbol: "AAPL", price: "100")
      allow(MarketData).to receive(:candles).and_return([ MarketData::Candle.new(time: 1, open: 1, high: 2, low: 1, close: 2, volume: 3) ])
      api(:get, "/assets/AAPL/candles?range=1M")
      expect(response.headers["Cache-Control"]).to include("public", "max-age=60")
      %w[/me /portfolio /orders /watchlist /sessions /account/export].each do |path|
        api(:get, path)
        expect([ path, response.headers["Cache-Control"] ]).to eq([ path, "private, no-store" ])
      end
    end

    it "never caches errors or authentication responses publicly" do
      api(:get, "/me")
      expect(response).to have_http_status(401)
      expect(response.headers["Cache-Control"]).to eq("private, no-store")
      api(:post, "/session", { email: "x@example.com", password: "bad-bad-bad" })
      expect(response.headers["Cache-Control"]).to eq("private, no-store")
    end
  end
end
