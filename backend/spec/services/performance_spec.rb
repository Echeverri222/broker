require "rails_helper"

RSpec.describe "performance [PERF]" do
  before { Clock.override = -> { Time.utc(2026, 3, 10, 16, 0, 0) } }
  let(:account) { create(:user).account }

  def snap(at, value, acct: account) = PortfolioSnapshot.create!(account: acct, total_value: value, cash: value, invested_value: 0, taken_at: at)

  def history(range = "1M", **kw) = Portfolios::History.call(account, range: range, **kw)

  before do
    account.portfolio_snapshots.delete_all
    account.deposits.update_all(created_at: Time.utc(2025, 12, 1)) # the initial deposit predates every range
  end

  it "returns zero gain with no snapshots [PERF-04]" do
    h = history
    expect(h).to include(return: "0.00", return_percent: "0.00")
    expect(h[:series].size).to eq(1)
  end

  it "uses the last snapshot at or before the range start [PERF-04]" do
    snap(Time.utc(2026, 1, 1), "90000"); snap(Time.utc(2026, 2, 5), "95000"); snap(Time.utc(2026, 3, 5), "98000")
    # now: 2026-03-10; 1W start = 03-03 -> start = the 02-05 snapshot (last at/before)
    h = history("1W")
    expect(h[:return]).to eq("5000.00") # live value is 100000 (cash)
    expect(h[:return_percent]).to eq("5.26")
    expect(h[:series].map { |p| p[:value] }).to eq(%w[98000.00 100000.00])
  end

  it "falls back to the first snapshot in range for a young account [PERF-04]" do
    snap(Time.utc(2026, 3, 8), "100000")
    expect(history("1M")[:return]).to eq("0.00")
  end

  it "excludes deposits after the start from the gain [PERF-04, DEP-04]" do
    snap(Time.utc(2026, 3, 1), "100000")
    account.deposits.create!(amount: 5000, kind: "deposit", created_at: Time.utc(2026, 3, 5))
    account.update!(cash: 105_000) # live value 105k, deposits +5k
    h = history("1M")
    expect(h).to include(deposits_in_range: "5000.00", return: "0.00", return_percent: "0.00")
  end

  it "ignores deposits made before the start [PERF-04]" do
    account.deposits.delete_all
    account.deposits.create!(amount: 5000, kind: "deposit", created_at: Time.utc(2026, 2, 1))
    snap(Time.utc(2026, 3, 1), "100000")
    account.update!(cash: 101_000)
    expect(history("1M")).to include(deposits_in_range: "0.00", return: "1000.00")
  end

  it "has a sorted series without duplicate timestamps ending at now [PERF-06]" do
    snap(Time.utc(2026, 3, 10, 16, 0, 0), "1"); snap(Time.utc(2026, 3, 9), "2"); snap(Time.utc(2026, 3, 9), "3")
    times = history("1W")[:series].map { |p| p[:time] }
    expect(times).to eq(times.uniq.sort)
    expect(times.last).to eq("2026-03-10T16:00:00Z")
  end

  it "rejects unknown ranges [PERF-08]" do
    expect { history("5Y") }.to raise_error(ApiError) { |e| expect(e.code).to eq(:validation_failed) }
  end

  describe "benchmark [PERF-07]" do
    let!(:spy) { Asset.create!(symbol: "SPY", name: "SPY", kind: "etf", provider_ref: "SPY") }

    it "buys SPY units at each deposit and values them over time" do
      account.deposits.delete_all
      account.deposits.create!(amount: 1000, kind: "initial", created_at: Time.utc(2026, 3, 1))
      account.update_columns(reset_at: Time.utc(2026, 3, 1))
      t = ->(d) { Time.utc(2026, 3, d).to_i }
      allow(MarketData).to receive(:history).and_return([ [ t[1], BigDecimal("100") ], [ t[5], BigDecimal("110") ], [ t[9], BigDecimal("120") ] ])
      snap(Time.utc(2026, 3, 6), "1000")
      b = history("1M", benchmark: true)[:benchmark]
      expect(b[:symbol]).to eq("SPY")
      expect(b[:series].map { |p| p[:value] }).to eq([ "1100.00", "1200.00" ]) # 10 units * 110, then * 120
    end

    it "returns benchmark: nil with an error message when SPY history fails, not a failed request" do
      allow(MarketData).to receive(:history).and_raise(MarketData::ProviderError, "down")
      h = history("1M", benchmark: true)
      expect(h[:benchmark]).to be_nil
      expect(h[:benchmark_error]).to be_present
      expect(h[:series]).not_to be_empty
    end
  end

  describe Snapshots::RecordAll do
    it "takes at most one close snapshot per account per day and skips holidays [PERF-05]" do
      Clock.override = -> { Time.utc(2026, 3, 10, 21, 5, 0) } # 17:05 ET Tuesday... after close
      account # create
      described_class.call(kind: :close)
      described_class.call(kind: :close)
      expect(account.portfolio_snapshots.where("taken_at >= ?", Time.utc(2026, 3, 10, 20)).count).to eq(1)
      Clock.override = -> { Time.utc(2026, 12, 25, 21, 5, 0) } # Christmas
      expect { described_class.call(kind: :close) }.not_to change(PortfolioSnapshot, :count)
    end

    it "hourly snapshots only accounts holding something whose market is open [PERF-05]" do
      Clock.override = -> { Time.utc(2026, 3, 7, 17, 0, 0) } # Saturday
      stock = with_asset(symbol: "AAPL")
      Orders::Place.call(account: account, symbol: "AAPL", side: "buy", amount: "100", idempotency_key: "x") rescue nil
      expect { described_class.call(kind: :hourly) }.not_to change(PortfolioSnapshot, :count)
    end
  end
end
