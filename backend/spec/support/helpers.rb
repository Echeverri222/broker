module BrokerHelpers
  # Monday 2026-03-02 11:00 ET: regular session, no holiday.
  OPEN_TIME = Time.utc(2026, 3, 2, 16, 0, 0)

  def with_asset(symbol: "AAPL", kind: "stock", price: "100", as_of: nil, fetched_at: nil)
    asset = Asset.create!(symbol: symbol, name: symbol, kind: kind)
    Quote.create!(asset: asset, price: BigDecimal(price), previous_close: BigDecimal(price),
                  change_percent: 0, as_of: as_of || Clock.now, fetched_at: fetched_at || Clock.now)
    asset
  end
end
RSpec.configure { |c| c.include BrokerHelpers }
