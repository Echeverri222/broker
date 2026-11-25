require "rails_helper"

RSpec.describe Orders::Place do
  let(:user) { create(:user) }
  let(:account) { user.account }
  let(:key_seq) { (1..1000).each }

  before { Clock.override = -> { BrokerHelpers::OPEN_TIME } }

  def place(**kw)
    described_class.call(account: account, symbol: "AAPL", side: "buy", idempotency_key: "k#{key_seq.next}", **kw)
  end

  def err(code, &blk)
    expect(&blk).to raise_error(ApiError) { |e| expect(e.code).to eq(code) }
  end

  describe "buy" do
    before { with_asset(price: "123.45678901") }

    it "buy by amount: total is exact, quantity floors to 8dp [MON-04]" do
      o = place(amount: "1000").order
      expect(o.total).to eq(BigDecimal("1000"))
      expect(o.quantity).to eq((BigDecimal("1000") / BigDecimal("123.45678901")).round(8, :down))
      expect(account.reload.cash).to eq(BigDecimal("99000"))
    end

    it "buy by quantity: total is rounded half up to cents [MON-04]" do
      o = place(quantity: "2.5").order
      expect(o.total).to eq((BigDecimal("2.5") * BigDecimal("123.45678901")).round(2, :half_up))
    end

    it "rounds a half-cent tie up [MON-04]" do
      Quote.update_all(price: BigDecimal("100.1"))
      # 0.05 * 100.1 = 5.005 -> 5.01
      expect(place(quantity: "0.05").order.total).to eq(BigDecimal("5.01"))
    end

    it "weights the average cost across 3 buys [MON-04, ORD-22]" do
      Quote.update_all(price: BigDecimal("100")); place(quantity: "1")
      Quote.update_all(price: BigDecimal("200")); place(quantity: "1")
      Quote.update_all(price: BigDecimal("300")); place(quantity: "1")
      pos = account.positions.first
      expect(pos.quantity).to eq(3)
      expect(pos.average_cost).to eq(BigDecimal("200"))
    end

    it "rejects insufficient funds with max_amount [ORD-06]" do
      expect { place(amount: "100000.01") }.to raise_error(ApiError) { |e|
        expect(e.code).to eq(:insufficient_funds)
        expect(e.details[:max_amount]).to eq("100000.00")
      }
    end

    it "rejects below $1 [ORD-04]" do
      err(:below_minimum) { place(amount: "0.99") }
    end

    it "rejects when quantity rounds to zero [ORD-04]" do
      Quote.update_all(price: BigDecimal("1000000000"))
      err(:below_minimum) { place(amount: "1.00") }
    end

    it "handles tiny prices [ORD-04, MON-04]" do
      Quote.update_all(price: BigDecimal("0.00012345"))
      o = place(amount: "10").order
      expect(o.quantity).to eq((BigDecimal("10") / BigDecimal("0.00012345")).round(8, :down))
    end
  end

  describe "input validation [ORD-01, ORD-02]" do
    before { with_asset }

    it "rejects bad shapes" do
      [ { amount: "1.234" }, { quantity: "0.123456789" }, { amount: "1e3" }, { amount: "-1" }, { amount: "0" },
        { amount: "" }, { amount: "NaN" }, { amount: " " }, { amount: "5", quantity: "1" }, {}, { amount: nil } ].each do |args|
        err(:validation_failed) { place(**args) }
      end
    end

    it "rejects sell_all on a buy and sell_all combined with an amount" do
      err(:validation_failed) { place(sell_all: true) }
      err(:validation_failed) { place(side: "sell", sell_all: true, amount: "5") }
    end

    it "rejects an invalid side" do
      err(:validation_failed) { place(side: "short", amount: "5") }
    end

    it "treats the symbol as case-insensitive and unknown assets as not_found [ORD-03]" do
      expect(place(symbol: "aapl", amount: "5").created).to be(true)
      err(:not_found) { place(symbol: "NOPE", amount: "5") }
    end
  end

  describe "sell" do
    before { with_asset(price: "100"); place(quantity: "10") }

    def sell(**kw) = place(side: "sell", **kw)

    it "keeps average cost, records realized P&L and keeps the position [ORD-22]" do
      Quote.update_all(price: BigDecimal("110"))
      o = sell(quantity: "5").order
      expect(o.realized_pnl).to eq(BigDecimal("50"))
      pos = account.positions.first
      expect(pos.quantity).to eq(5)
      expect(pos.average_cost).to eq(BigDecimal("100"))
    end

    it "records a negative realized P&L for a loss and zero at break-even" do
      Quote.update_all(price: BigDecimal("90"))
      expect(sell(quantity: "1").order.realized_pnl).to eq(BigDecimal("-10"))
      Quote.update_all(price: BigDecimal("100"))
      expect(sell(quantity: "1").order.realized_pnl).to eq(0)
    end

    it "sell_all closes the position and a re-buy starts a fresh average [ORD-05, ORD-22]" do
      Quote.update_all(price: BigDecimal("150"))
      o = sell(sell_all: true).order
      expect(o.quantity).to eq(10)
      expect(account.positions.count).to eq(0)
      place(quantity: "1")
      expect(account.positions.first.average_cost).to eq(150)
    end

    it "sell_all closes dust under $1 [ORD-04]" do
      Quote.update_all(price: BigDecimal("0.5"))
      account.positions.first.update!(quantity: BigDecimal("1"))
      o = sell(sell_all: true).order
      expect(o.total).to eq(BigDecimal("0.5"))
    end

    it "sell_all on dust worth under a cent is refused rather than minting a zero-total order" do
      Quote.update_all(price: BigDecimal("0.001"))
      account.positions.first.update!(quantity: BigDecimal("1"))
      err(:below_minimum) { sell(sell_all: true) }
    end

    it "over-selling returns max_quantity and max_amount, with no implicit sell-all [ORD-05]" do
      expect { sell(quantity: "10.00000001") }.to raise_error(ApiError) { |e|
        expect(e.code).to eq(:insufficient_quantity)
        expect(e.details).to include(max_quantity: "10.00000000", max_amount: "1000.00")
      }
      err(:insufficient_quantity) { sell(amount: "1000.01") }
      expect(account.positions.first.quantity).to eq(10)
    end

    it "selling with no position is insufficient_quantity [ORD-07]" do
      with_asset(symbol: "MSFT")
      err(:insufficient_quantity) { place(symbol: "MSFT", side: "sell", amount: "5") }
      err(:insufficient_quantity) { place(symbol: "MSFT", side: "sell", sell_all: true) }
    end

    it "sell by amount below $1 is below_minimum [ORD-04]" do
      err(:below_minimum) { sell(amount: "0.50") }
    end
  end

  describe "price and hours" do
    it "refetches a stale quote before filling [ORD-10]" do
      asset = with_asset(price: "100", fetched_at: Clock.now - 5.minutes)
      q = MarketData::Quote.new(price: BigDecimal("101"), previous_close: BigDecimal("100"), change: 1, change_percent: 1, as_of: Clock.now)
      expect(MarketData).to receive(:quote).with(asset).and_return(q)
      expect(place(amount: "101").order.price).to eq(101)
    end

    it "rejects a quote whose as_of is too old even if fetched recently [ORD-11]" do
      with_asset(as_of: Clock.now - 16.minutes)
      err(:price_unavailable) { place(amount: "10") }
    end

    it "accepts a stock quote 14 minutes old and applies 5 min for crypto [ORD-11]" do
      with_asset(as_of: Clock.now - 14.minutes)
      expect(place(amount: "10").created).to be(true)
      with_asset(symbol: "BTC", kind: "crypto", as_of: Clock.now - 6.minutes)
      err(:price_unavailable) { place(symbol: "BTC", amount: "10") }
    end

    it "maps provider failures to price_unavailable [ORD-12]" do
      with_asset(fetched_at: Clock.now - 5.minutes)
      allow(MarketData).to receive(:quote).and_raise(MarketData::ProviderError, "boom")
      err(:price_unavailable) { place(amount: "10") }
      expect(account.reload.cash).to eq(100_000)
    end

    it "queues stocks when the market is closed instead of filling [ORD-13, QUE-01]" do
      with_asset
      Clock.override = -> { Time.utc(2026, 3, 7, 16, 0, 0) } # Saturday
      o = place(amount: "10").order
      expect(o).to have_attributes(status: "pending", quantity: nil, price: nil, total: nil, amount: BigDecimal("10"))
      expect(account.reload.cash).to eq(100_000)
    end

    it "refuses when the market is closed and no next session is known [ORD-13]" do
      with_asset
      Clock.override = -> { Time.utc(2028, 1, 3, 16, 0, 0) } # past COVERED_THROUGH
      expect { place(amount: "10") }.to raise_error(ApiError) { |e|
        expect(e.code).to eq(:market_closed)
        expect(e.details[:next_open]).to be_nil
      }
    end

    it "lets crypto trade when the stock market is closed [ORD-13]" do
      Clock.override = -> { Time.utc(2026, 3, 7, 16, 0, 0) }
      with_asset(symbol: "BTC", kind: "crypto", price: "50000")
      expect(place(symbol: "BTC", amount: "1000").created).to be(true)
    end

    it "decides on a single timestamp around 16:00:00 ET [ORD-14]" do
      Clock.override = -> { Time.utc(2026, 3, 2, 20, 59, 59, 999_000) }
      with_asset
      expect(place(amount: "10").created).to be(true)
      Clock.override = -> { Time.utc(2026, 3, 2, 21, 0, 0) }
      expect(place(amount: "10").order.status).to eq("pending")
    end
  end

  describe "idempotency [ORD-24]" do
    before { with_asset }

    it "requires a key" do
      err(:idempotency_key_required) { described_class.call(account: account, symbol: "AAPL", side: "buy", amount: "10") }
    end

    it "returns the original order for the same key and body" do
      first = described_class.call(account: account, symbol: "AAPL", side: "buy", amount: "10", idempotency_key: "same")
      again = described_class.call(account: account, symbol: "AAPL", side: "buy", amount: "10", idempotency_key: "same")
      expect([ first.created, again.created ]).to eq([ true, false ])
      expect(again.order).to eq(first.order)
      expect(account.orders.count).to eq(1)
    end

    it "conflicts when the same key is used with a different body" do
      described_class.call(account: account, symbol: "AAPL", side: "buy", amount: "10", idempotency_key: "same")
      err(:idempotency_conflict) do
        described_class.call(account: account, symbol: "AAPL", side: "buy", amount: "11", idempotency_key: "same")
      end
    end

    it "stores nothing for a rejected request, so a retry with the same key runs again" do
      err(:insufficient_funds) { described_class.call(account: account, symbol: "AAPL", side: "buy", amount: "999999", idempotency_key: "retry") }
      expect(account.orders.count).to eq(0)
      account.update!(cash: 1_000_000)
      expect(described_class.call(account: account, symbol: "AAPL", side: "buy", amount: "999999", idempotency_key: "retry").created).to be(true)
    end
  end

  it "filled orders are immutable [ORD-23]" do
    with_asset
    o = place(amount: "10").order
    expect { o.update!(total: 1) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { o.destroy }.not_to change(Order, :count)
  end
end
