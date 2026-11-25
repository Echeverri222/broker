require "rails_helper"

RSpec.describe CorporateActions do
  before { Clock.override = -> { BrokerHelpers::OPEN_TIME } }
  let(:account) { create(:user).account }
  let(:asset) { with_asset(symbol: "SPL", price: "100") }

  def hold(qty, price: "100")
    Quote.where(asset: asset).update_all(price: BigDecimal(price))
    Orders::Place.call(account: account, symbol: "SPL", side: "buy", quantity: qty, idempotency_key: SecureRandom.hex(4))
    # make the position predate the effective date
    Position.update_all(created_at: Time.utc(2026, 3, 1))
  end

  def split(ratio, date: Date.new(2026, 3, 3)) = CorporateActions::ApplySplit.call(asset: asset, ratio: ratio, effective_date: date)

  {
    "2:1" => [ "2", "10", "20", "50" ],
    "10:1" => [ "10", "10", "100", "10" ],
    "reverse 1:10" => [ "0.1", "100", "10", "1000" ],
    "3:2 fractional" => [ "1.5", "10", "15", "66.66666667" ]
  }.each do |name, (ratio, qty, new_qty, new_avg)|
    it "applies a #{name} split, preserving cost basis within a cent [CA-03]" do
      hold(qty)
      expect(split(ratio)).to eq(:applied)
      pos = account.positions.first
      expect(pos.quantity).to eq(BigDecimal(new_qty))
      expect(pos.average_cost).to eq(BigDecimal(new_avg))
      expect((pos.quantity * pos.average_cost - BigDecimal(qty) * 100).abs).to be < BigDecimal("0.01")
      expect(PositionAdjustment.count).to eq(1)
      expect(Ledger::Verify.call).to be_empty # MON-06 accounts for splits
    end
  end

  it "is idempotent on re-run [CA-02]" do
    hold("10")
    expect(split("2")).to eq(:applied)
    expect(split("2")).to eq(:duplicate)
    expect(account.positions.first.quantity).to eq(20)
    expect(CorporateAction.count).to eq(1)
  end

  it "records a split on an asset nobody holds without error [CA-02]" do
    expect(split("2")).to eq(:no_holders)
    expect(CorporateAction.count).to eq(1)
  end

  it "skips positions opened on or after the effective date [CA-03]" do
    hold("10")
    Position.update_all(created_at: Time.utc(2026, 3, 3, 15))
    split("2")
    expect(account.positions.first.quantity).to eq(10)
  end

  it "floors fractional results to 8dp" do
    hold("0.33333333")
    split("1.5")
    expect(account.positions.first.quantity).to eq(BigDecimal("0.49999999"))
  end

  describe "Sync [CA-01]" do
    it "imports splits for held assets and SPY only, and tolerates provider failures" do
      hold("10")
      spy = Asset.create!(symbol: "SPY", name: "SPY", kind: "etf")
      Asset.create!(symbol: "OTHER", name: "Other", kind: "stock")
      calls = []
      allow(MarketData).to receive(:splits) do |a, from:|
        calls << a.symbol
        raise MarketData::ProviderError, "down" if a == spy
        [ [ Date.new(2026, 3, 3), BigDecimal("2") ] ]
      end
      described_class::Sync.call
      expect(calls).to contain_exactly("SPL", "SPY")
      expect(account.positions.first.quantity).to eq(20)
    end
  end

  describe "Yahoo splits parsing [MKT-01, MKT-02]" do
    let(:provider) { MarketData::YahooProvider.new }
    let(:asset) { Asset.create!(symbol: "NVDA", name: "N", kind: "stock", provider_ref: "NVDA") }

    it "parses a recorded split event" do
      body = { chart: { result: [ { events: { splits: { "1717000000" => { date: 1717000000, numerator: 10, denominator: 1, splitRatio: "10:1" } } } } ] } }
      stub_request(:get, /query1.finance.yahoo.com/).to_return(status: 200, body: body.to_json)
      expect(provider.splits(asset, from: 1.year.ago)).to eq([ [ Date.new(2024, 5, 29), BigDecimal("10") ] ])
    end

    it "raises ProviderError on malformed splits, HTTP errors and bad JSON" do
      stub_request(:get, /yahoo/).to_return(status: 200, body: { chart: { result: [ { events: { splits: { "1" => { date: 1, numerator: nil, denominator: 1 } } } } ] } }.to_json)
      expect { provider.splits(asset, from: 1.day.ago) }.to raise_error(MarketData::ProviderError)
      stub_request(:get, /yahoo/).to_return(status: 429, body: "")
      expect { provider.splits(asset, from: 1.day.ago) }.to raise_error(MarketData::ProviderError)
      stub_request(:get, /yahoo/).to_return(status: 200, body: "<html>")
      expect { provider.splits(asset, from: 1.day.ago) }.to raise_error(MarketData::ProviderError)
    end
  end
end
