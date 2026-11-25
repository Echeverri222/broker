require "rails_helper"

RSpec.describe "Today's change and typo search" do
  let(:user) { create(:user) }
  let(:account) { user.account }

  before { Clock.override = -> { BrokerHelpers::OPEN_TIME } } # Monday 11:00 ET

  def valuation = Portfolios::Valuate.call(account)

  it "counts only moves since purchase for a position bought today [PERF-01]" do
    asset = with_asset(price: "100")
    Quote.update_all(previous_close: BigDecimal("90"))
    Orders::Place.call(account: account, symbol: "AAPL", side: "buy", quantity: "10", idempotency_key: "a")
    Quote.update_all(price: BigDecimal("105"))
    v = valuation
    expect(v.day_change).to eq(BigDecimal("50")) # 10 * (105 - 100), not 10 * (105 - 90)
    expect(v.rows.first.day_percent.round(2)).to eq(BigDecimal("5.0"))
    expect(asset).to be_persisted
  end

  it "uses the previous close for a position held since before today [PERF-01]" do
    with_asset(price: "100")
    Quote.update_all(previous_close: BigDecimal("90"))
    pos = account.positions.create!(asset: Asset.first, quantity: 10, average_cost: 80)
    pos.update_columns(created_at: 3.days.ago)
    expect(valuation.day_change).to eq(BigDecimal("100"))
  end

  it "keeps today's gain from a position opened and closed today [PERF-01]" do
    with_asset(price: "100")
    Orders::Place.call(account: account, symbol: "AAPL", side: "buy", quantity: "10", idempotency_key: "b")
    Quote.update_all(price: BigDecimal("110"))
    Orders::Place.call(account: account, symbol: "AAPL", side: "sell", sell_all: true, idempotency_key: "c")
    expect(valuation.day_change).to eq(BigDecimal("100"))
  end

  it "finds assets despite typos but not nonsense [UX-09]" do
    Asset.create!(symbol: "AAPL", name: "Apple Inc.", kind: "stock")
    Asset.create!(symbol: "BTC", name: "Bitcoin", kind: "crypto")
    expect(Asset.fuzzy("aple").pluck(:symbol)).to eq([ "AAPL" ])
    expect(Asset.fuzzy("bitcon").pluck(:symbol)).to eq([ "BTC" ])
    expect(Asset.fuzzy("zzqxwv")).to be_empty
    expect(Asset.fuzzy("ab")).to be_empty
  end
end
