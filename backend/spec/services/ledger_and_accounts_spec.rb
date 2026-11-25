require "rails_helper"

RSpec.describe "ledger, deposits, valuation, signup and reset" do
  before { Clock.override = -> { BrokerHelpers::OPEN_TIME } }

  let(:user) { create(:user) }
  let(:account) { user.account }

  def buy(sym, amount, key: SecureRandom.hex(4))
    Orders::Place.call(account: account, symbol: sym, side: "buy", amount: amount, idempotency_key: key)
  end

  describe Deposits::Create do
    it "adds exactly the amount, a ledger row and a snapshot [DEP-03]" do
      expect { described_class.call(account: account, amount: "5000.25", idempotency_key: "d1") }
        .to change { account.reload.cash }.by(BigDecimal("5000.25"))
        .and change { account.deposits.count }.by(1)
        .and change { account.portfolio_snapshots.count }.by(1)
    end

    it "validates the range and precision [DEP-01]" do
      expect { described_class.call(account: account, amount: "0.99", idempotency_key: "a") }.to raise_error(ApiError) { |e| expect(e.code).to eq(:below_minimum) }
      expect { described_class.call(account: account, amount: "10000000.01", idempotency_key: "b") }.to raise_error(ApiError) { |e| expect(e.code).to eq(:validation_failed) }
      expect { described_class.call(account: account, amount: "1.001", idempotency_key: "c") }.to raise_error(ApiError) { |e| expect(e.code).to eq(:validation_failed) }
      expect { described_class.call(account: account, amount: "1e3", idempotency_key: "d") }.to raise_error(ApiError) { |e| expect(e.code).to eq(:validation_failed) }
    end

    it "requires an idempotency key and handles replay/conflict [DEP-02]" do
      expect { described_class.call(account: account, amount: "5") }.to raise_error(ApiError) { |e| expect(e.code).to eq(:idempotency_key_required) }
      first = described_class.call(account: account, amount: "5", idempotency_key: "k")
      again = described_class.call(account: account, amount: "5", idempotency_key: "k")
      expect([ first.created, again.created ]).to eq([ true, false ])
      expect(account.deposits.where(kind: "deposit").count).to eq(1)
      expect { described_class.call(account: account, amount: "6", idempotency_key: "k") }.to raise_error(ApiError) { |e| expect(e.code).to eq(:idempotency_conflict) }
    end

    it "does not change total return [DEP-04, PERF-03]" do
      described_class.call(account: account, amount: "5000", idempotency_key: "x")
      v = Portfolios::Valuate.call(account.reload)
      expect(v.total_value - account.net_deposits).to eq(0)
    end
  end

  describe Portfolios::Valuate do
    it "never invents a price when the quote is missing [MKT-04]" do
      a = with_asset(symbol: "AAPL", price: "100")
      buy("AAPL", "1000")
      a.quote.destroy!
      v = described_class.call(account.reload)
      expect(v.incomplete).to be(true)
      expect(v.rows.first.price).to be_nil
      expect(v.total_value).to eq(account.cash)
      json = Presenters.portfolio(account, v)
      expect(json).to include(incomplete: true)
      expect(json[:positions].first).to include(price: nil, price_status: "missing", market_value: nil)
    end

    it "computes total, day change and percentages [PERF-01, PERF-02]" do
      with_asset(symbol: "AAPL", price: "100")
      buy("AAPL", "1000")
      Quote.update_all(price: BigDecimal("110"), previous_close: BigDecimal("105"))
      v = described_class.call(account.reload)
      expect(v.invested_value).to eq(1100)
      expect(v.total_value).to eq(100_100)
      expect(v.day_change).to eq(100) # bought today at 100: only the move since purchase counts
      j = Presenters.portfolio(account, v)
      expect(j[:total_return]).to eq("100.00")
      expect(j[:total_return_percent]).to eq("0.10")
    end
  end

  describe "signup and reset atomicity [AUTH-01, RST-02]" do
    it "provision gives starting cash, an initial deposit and a snapshot" do
      expect(account.cash).to eq(100_000)
      expect(account.deposits.pluck(:kind)).to eq(%w[initial])
      expect(account.portfolio_snapshots.count).to eq(1)
    end

    it "leaves nothing behind when provisioning fails mid-signup [AUTH-01]" do
      allow(Snapshots::Record).to receive(:call).and_raise("boom")
      expect {
        User.transaction do
          u = User.create!(name: "X", email: "x@example.com", password: "password123")
          Accounts::Provision.call(u.create_account!(cash: 0))
        end
      }.to raise_error("boom")
      expect(User.where(email: "x@example.com")).to be_empty
      expect(Account.count).to eq(0)
    end

    it "resets everything atomically and restores the ledger [RST-01..03]" do
      with_asset(symbol: "AAPL")
      buy("AAPL", "1000")
      user.watchlist_items.create!(asset: Asset.first)
      expect { Accounts::Reset.call(account, confirm: "reset") }.to raise_error(ApiError)
      Accounts::Reset.call(account, confirm: "RESET")
      account.reload
      expect(account.cash).to eq(100_000)
      expect(account.positions).to be_empty
      expect(account.orders).to be_empty
      expect(account.deposits.pluck(:kind)).to eq(%w[initial])
      expect(account.portfolio_snapshots.count).to eq(1)
      expect(account.reset_at).to be_present
      expect(user.watchlist_items.count).to eq(1)
      expect(Ledger::Verify.call).to be_empty
    end

    it "a failure during reset rolls everything back [RST-02]" do
      with_asset(symbol: "AAPL")
      buy("AAPL", "1000")
      allow(Snapshots::Record).to receive(:call).and_raise("boom")
      expect { Accounts::Reset.call(account, confirm: "RESET") }.to raise_error("boom")
      account.reload
      expect(account.cash).to eq(99_000)
      expect(account.positions.count).to eq(1)
      expect(account.orders.count).to eq(1)
    end

    it "does not touch other users [AUTH-08]" do
      other = create(:user)
      Accounts::Reset.call(account, confirm: "RESET")
      expect(other.account.reload.cash).to eq(100_000)
    end
  end

  describe Ledger::Verify do
    it "passes on a consistent database [MON-08]" do
      with_asset(symbol: "AAPL")
      buy("AAPL", "1000")
      expect(described_class.call).to be_empty
    end

    it "flags a corrupted cash balance or position [MON-05, MON-06, MON-08]" do
      with_asset(symbol: "AAPL")
      buy("AAPL", "1000")
      account.update_columns(cash: 5)
      account.positions.first.update_columns(quantity: 999)
      rules = described_class.call.map { |p| p[:rule] }
      expect(rules).to contain_exactly("MON-05", "MON-06")
    end
  end

  describe "randomized sequences [MON-05, MON-06, MON-07]" do
    it "keeps the ledger consistent over random deposits, buys, sells and resets" do
      seed = (ENV["SEED"] || Random.new_seed).to_i
      puts "randomized seed=#{seed}"
      rng = Random.new(seed)
      assets = %w[AAA BBB CCC].map { |s| with_asset(symbol: s, price: "100") }
      30.times do |seq|
        acct = create(:user).account
        30.times do |step|
          asset = assets.sample(random: rng)
          Quote.where(asset: asset).update_all(price: BigDecimal(format("%.4f", rng.rand(0.01..900.0))))
          key = "r#{seq}-#{step}"
          begin
            case rng.rand(6)
            when 0 then Deposits::Create.call(account: acct, amount: format("%.2f", rng.rand(1.0..5000.0)), idempotency_key: key)
            when 1, 2 then Orders::Place.call(account: acct, symbol: asset.symbol, side: "buy", amount: format("%.2f", rng.rand(1.0..30_000.0)), idempotency_key: key)
            when 3 then Orders::Place.call(account: acct, symbol: asset.symbol, side: "sell", quantity: format("%.8f", rng.rand(0.0001..50.0)), idempotency_key: key)
            when 4 then Orders::Place.call(account: acct, symbol: asset.symbol, side: "sell", sell_all: true, idempotency_key: key)
            else Accounts::Reset.call(acct, confirm: "RESET") if rng.rand < 0.1
            end
          rescue ApiError
            # rejected requests must leave no trace
          end
          acct.reload
          expect(acct.cash).to be >= 0
          expect(acct.positions.pluck(:quantity)).to all(be > 0)
        end
        expect(Ledger::Verify.call).to be_empty, "seed #{seed}"
      end
    end
  end
end
