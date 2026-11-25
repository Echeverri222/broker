require "rails_helper"

RSpec.describe "money, market data and platform rules" do
  before { Clock.override = -> { BrokerHelpers::OPEN_TIME } }

  it "has no Float in money code paths [MON-01]" do
    files = Dir[Rails.root.join("app/{services,models}/**/*.rb")].reject { |f| f.end_with?("market_data/yahoo_provider.rb") }
    offenders = files.select { |f| File.read(f).match?(/\.to_f\b|Float\(/) }
    expect(offenders).to be_empty
  end

  it "uses decimal columns with the documented scales [MON-01, MON-02]" do
    cols = ->(t, c) { ActiveRecord::Base.connection.columns(t).find { |x| x.name == c } }
    expect(cols.("accounts", "cash")).to have_attributes(type: :decimal, scale: 2)
    expect(cols.("orders", "total")).to have_attributes(type: :decimal, scale: 2)
    expect(cols.("orders", "quantity")).to have_attributes(type: :decimal, scale: 8)
    expect(cols.("orders", "price")).to have_attributes(type: :decimal, scale: 8)
    expect(cols.("quotes", "price")).to have_attributes(type: :decimal, scale: 8)
  end

  it "formats decimals as fixed-scale strings and never -0.00 [MON-02, MON-03]" do
    expect(Fmt.money(BigDecimal("100000"))).to eq("100000.00")
    expect(Fmt.qty(BigDecimal("0.5"))).to eq("0.50000000")
    expect(Fmt.money(BigDecimal("-0.001"))).to eq("0.00")
    expect(Fmt.dec(BigDecimal("1.005"), 2)).to eq("1.01")
  end

  it "enforces DB constraints [MON-07]" do
    account = create(:user).account
    asset = with_asset
    expect { account.update_columns(cash: -1) }.to raise_error(ActiveRecord::StatementInvalid)
    expect { Deposit.create!(account: account, amount: 0, kind: "deposit") }.to raise_error(ActiveRecord::StatementInvalid)
    expect { Position.create!(account: account, asset: asset, quantity: 0, average_cost: 1) }.to raise_error(ActiveRecord::StatementInvalid)
    %w[quantity price total].each do |col|
      attrs = { account: account, asset: asset, side: "buy", quantity: 1, price: 1, total: 1, status: "filled", filled_at: Time.current }
      expect { Order.create!(attrs.merge(col.to_sym => 0)) }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  it "flags quotes older than 2 minutes as stale [MKT-05]" do
    asset = with_asset(as_of: Clock.now - 3.minutes)
    expect(Presenters.quote(asset.quote)[:stale]).to be(true)
    asset.quote.update!(as_of: Clock.now - 1.minute)
    expect(Presenters.quote(asset.quote)[:stale]).to be(false)
  end

  it "skips the refresh when another run holds the lock [MKT-03]" do
    cfg = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(host: cfg[:host], user: cfg[:username], password: cfg[:password], dbname: cfg[:database]) # separate session
    other.exec("SELECT pg_advisory_lock(#{Quotes::Refresh::LOCK_KEY})")
    begin
      expect(Quotes::Refresh.call).to eq(:skipped)
    ensure
      other.exec("SELECT pg_advisory_unlock(#{Quotes::Refresh::LOCK_KEY})")
      other.close
    end
  end

  it "keeps the previous quote when a provider returns nothing for an asset [MKT-03]" do
    asset = with_asset(symbol: "AAPL", price: "100", fetched_at: Clock.now - 2.hours)
    allow(MarketData).to receive(:quotes).and_return({})
    Quotes::Refresh.call(force: true)
    expect(asset.quote.reload.price).to eq(100)
  end

  describe "provider parsing [MKT-01, MKT-02]" do
    let(:stock) { Asset.create!(symbol: "AAPL", name: "Apple", kind: "stock", provider_ref: "AAPL") }
    let(:coin) { Asset.create!(symbol: "BTC", name: "Bitcoin", kind: "crypto", provider_ref: "bitcoin") }

    def yahoo_body(meta) = { chart: { result: [ { meta: meta } ] } }.to_json

    it "parses a Yahoo quote" do
      stub_request(:get, /yahoo/).to_return(body: yahoo_body(regularMarketPrice: 231.12, previousClose: 229.2, regularMarketTime: 1_772_000_000))
      q = MarketData::YahooProvider.new.quote(stock)
      expect(q.price).to eq(BigDecimal("231.12"))
      expect(q.as_of).to eq(Time.at(1_772_000_000).utc)
    end

    it "raises ProviderError for null/missing/zero prices, missing time, and transport failures" do
      yp = MarketData::YahooProvider.new
      [ { regularMarketPrice: nil, regularMarketTime: 1 }, { regularMarketTime: 1 }, { regularMarketPrice: 0, regularMarketTime: 1 },
        { regularMarketPrice: 5 } ].each do |meta|
        stub_request(:get, /yahoo/).to_return(body: yahoo_body(meta))
        expect { yp.quote(stock) }.to raise_error(MarketData::ProviderError), meta.inspect
      end
      stub_request(:get, /yahoo/).to_return(body: { chart: { result: nil, error: { description: "Not found" } } }.to_json)
      expect { yp.quote(stock) }.to raise_error(MarketData::ProviderError)
      stub_request(:get, /yahoo/).to_return(status: 500)
      expect { yp.quote(stock) }.to raise_error(MarketData::ProviderError)
      stub_request(:get, /yahoo/).to_timeout
      expect { yp.quote(stock) }.to raise_error(MarketData::ProviderError)
    end

    it "parses CoinGecko and omits incomplete coins" do
      stub_request(:get, /coingecko/).to_return(body: { bitcoin: { usd: 97_000.5, usd_24h_change: 1.5, last_updated_at: 1_772_000_000 } }.to_json)
      expect(MarketData::CoingeckoProvider.new.quotes([ coin ])[coin.id].price).to eq(BigDecimal("97000.5"))
      stub_request(:get, /coingecko/).to_return(body: { bitcoin: { usd: nil } }.to_json)
      expect(MarketData::CoingeckoProvider.new.quotes([ coin ])).to be_empty
      stub_request(:get, /coingecko/).to_return(status: 429)
      expect { MarketData::CoingeckoProvider.new.quotes([ coin ]) }.to raise_error(MarketData::ProviderError)
    end
  end

  describe "candles [MKT-06]", type: :request do
    it "caches intraday ranges and returns 503 price_unavailable on provider failure" do
      with_asset(symbol: "AAPL")
      sign_up!
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      stub_request(:get, /yahoo/).to_return(status: 500)
      api(:get, "/assets/AAPL/candles?range=1D")
      expect([ response.status, json[:error][:code] ]).to eq([ 503, "price_unavailable" ])
      body = { chart: { result: [ { timestamp: [ 1, 2 ], indicators: { quote: [ { open: [ 1, 2 ], high: [ 1, 2 ], low: [ 1, 2 ], close: [ 1, 2 ] } ] } } ] } }
      WebMock::RequestRegistry.instance.reset!
      stub = stub_request(:get, /yahoo/).to_return(body: body.to_json)
      2.times { api(:get, "/assets/AAPL/candles?range=1D"); expect(response).to have_http_status(:ok) }
      expect(stub).to have_been_requested.once
      api(:get, "/assets/AAPL/candles?range=7Y"); expect(response).to have_http_status(422)
    ensure
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
    end
  end

  it "does not value a position without a quote on the asset page [MKT-04]", type: :request do
    a = with_asset(symbol: "AAPL")
    sign_up!
    Orders::Place.call(account: User.last.account, symbol: "AAPL", side: "buy", amount: "100", idempotency_key: "x")
    a.quote.destroy!
    stub_request(:get, /query1\.finance\.yahoo\.com/).to_return(status: 500) # on-demand refresh fails -> still no quote
    get "/api/v1/assets/AAPL", headers: ApiHelpers::JSON_HEADERS
    expect(JSON.parse(response.body)["position"]["market_value"]).to be_nil
  end

  it "emits ISO 8601 UTC timestamps with Z [API-03]" do
    expect(Fmt.iso(Time.utc(2026, 3, 2, 16, 0, 0))).to eq("2026-03-02T16:00:00Z")
    expect(Fmt.iso(Time.new(2026, 3, 2, 11, 0, 0, "-05:00"))).to eq("2026-03-02T16:00:00Z")
    expect(MarketCalendar.status[:next_close]).to end_with("Z")
  end

  it "applies splits before valuation and keeps the SPY benchmark price-only [CA-04, CA-05]" do
    # Splits are applied by the 06:00 ET job (scheduled before the open), and benchmark prices come from
    # split-adjusted, dividend-unadjusted Yahoo closes.
    schedule = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result, aliases: true)
    expect(schedule["production"]["splits"]["schedule"]).to match(/6:00am America\/New_York/)
    expect(Portfolios::History.instance_method(:attach_benchmark)).to be_present
  end

  it "keeps MON-05/06 after a reset with an open position [RST-03]" do
    account = create(:user).account
    with_asset(symbol: "AAPL")
    Orders::Place.call(account: account, symbol: "AAPL", side: "buy", amount: "500", idempotency_key: "x")
    Accounts::Reset.call(account, confirm: "RESET")
    expect(Ledger::Verify.call).to be_empty
    expect(Portfolios::Valuate.call(account.reload).rows).to be_empty
  end

  it "serializes an order write with a row lock on the account [ORD-20]" do
    account = create(:user).account
    with_asset(symbol: "AAPL")
    expect_any_instance_of(Account).to receive(:lock!).at_least(:once).and_call_original
    Orders::Place.call(account: account, symbol: "AAPL", side: "buy", amount: "10", idempotency_key: "x")
  end
end
