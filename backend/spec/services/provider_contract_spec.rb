require "rails_helper"

# MKD-08 [D3]: the provider interface is the seam where a licensed feed replaces Yahoo and CoinGecko. Callers only
# ever use these methods, so every provider must answer them the same way, and nothing outside the providers may
# know a vendor's URL or payload shape.
RSpec.describe "Provider contract [MKD-08]" do
  YAHOO_JSON = {
    "chart" => { "result" => [ { "meta" => { "regularMarketPrice" => 101.5, "chartPreviousClose" => 100.0, "regularMarketTime" => Time.utc(2026, 3, 2, 15, 59).to_i },
                                 "timestamp" => [ Time.utc(2026, 3, 2, 15, 0).to_i ],
                                 "indicators" => { "quote" => [ { "open" => [ 100.0 ], "high" => [ 102.0 ], "low" => [ 99.0 ], "close" => [ 101.5 ], "volume" => [ 1000 ] } ] } } ], "error" => nil }
  }.freeze

  let(:stock) { Asset.create!(symbol: "AAPL", name: "Apple", kind: "stock", provider_ref: "AAPL") }
  let(:coin) { Asset.create!(symbol: "BTC", name: "Bitcoin", kind: "crypto", provider_ref: "bitcoin") }

  def stub_yahoo = stub_request(:get, /query1\.finance\.yahoo\.com/).to_return(status: 200, body: YAHOO_JSON.to_json, headers: { "Content-Type" => "application/json" })

  it "defines the full interface on the stock provider" do
    %i[quote quotes candles history splits overview].each { |m| expect(MarketData::YahooProvider.instance_methods).to include(m) }
  end

  it "defines the batch quote method on the crypto provider, with the same return shape" do
    expect(MarketData::CoingeckoProvider.instance_methods).to include(:quotes)
  end

  shared_examples "a quote provider" do |provider_class, asset_name, stub|
    it "returns a hash keyed by asset id with price, previous close and timestamps, as BigDecimal and Time" do
      send(stub)
      asset = send(asset_name)
      result = provider_class.new.quotes([ asset ])
      expect(result.keys).to eq([ asset.id ]) # keyed by asset id
      q = result[asset.id]
      expect(q).to be_a(MarketData::Quote)
      expect([ q.price, q.previous_close, q.change, q.change_percent ].map(&:class).uniq).to eq([ BigDecimal ])
      expect(q.as_of).to be_a(Time)
      expect(q.price).to be_positive
    end

    it "omits an asset it cannot price instead of returning nil or zero [MKT-02]" do
      stub_request(:any, /.*/).to_return(status: 200, body: {}.to_json, headers: { "Content-Type" => "application/json" })
      expect(provider_class.new.quotes([ send(asset_name) ])).to eq({})
    end

    it "reports a vendor failure as ProviderError or as a missing quote, never as a vendor exception" do
      stub_request(:any, /.*/).to_return(status: 503, body: "down")
      result = begin
        provider_class.new.quotes([ send(asset_name) ])
      rescue MarketData::ProviderError
        {}
      end
      expect(result).to eq({}) # the caller keeps the stored quote and flags it stale
    end
  end

  describe MarketData::YahooProvider do
    include_examples "a quote provider", MarketData::YahooProvider, :stock, :stub_yahoo
  end

  describe MarketData::CoingeckoProvider do
    def stub_coingecko
      stub_request(:get, /api\.coingecko\.com/).to_return(status: 200,
        body: { "bitcoin" => { "usd" => 50_000, "usd_24h_change" => 1.5, "last_updated_at" => Time.utc(2026, 3, 2, 15, 59).to_i } }.to_json,
        headers: { "Content-Type" => "application/json" })
    end
    include_examples "a quote provider", MarketData::CoingeckoProvider, :coin, :stub_coingecko
  end

  it "keeps vendor knowledge inside the provider classes: no other code names a vendor host" do
    offenders = Dir[Rails.root.join("app/**/*.rb")].reject { |f| f.include?("/market_data/") }.select { |f| File.read(f).match?(/yahoo\.com|coingecko\.com/) }
    expect(offenders).to eq([])
  end

  it "reaches providers only through the gateway, so any replacement gets the budget and breaker for free [MKD-06]" do
    stub_yahoo
    before = MarketData::Gateway.calls_this_minute("yahoo")
    MarketData::YahooProvider.new.quotes([ stock ])
    expect(MarketData::Gateway.calls_this_minute("yahoo")).to eq(before + 1)
  end
end
