require "rails_helper"

# PRD v3 data rules DAT-01..08. Provider calls are WebMock stubs; the list endpoint must never reach a provider.
RSpec.describe "UI v3 data", type: :request do
  before { Clock.override = -> { BrokerHelpers::OPEN_TIME } } # Monday 11:00 ET, market open
  before { stub_request(:get, /yahoo|coingecko/).to_return(status: 500) } # on-demand refreshes fail quietly; examples restub what they need

  def candle_body(volume: [ 1_000, 2_500 ])
    q = { open: [ 1, 2 ], high: [ 2, 3 ], low: [ 1, 2 ], close: [ 1.5, 2.5 ] }
    q[:volume] = volume if volume
    { chart: { result: [ { timestamp: [ 1_772_000_000, 1_772_086_400 ], indicators: { quote: [ q ] } } ] } }.to_json
  end

  def seed_universe
    {
      "AAPL" => [ "stock", "100", "98", "2.04" ], "MSFT" => [ "stock", "40", "41", "-2.44" ], "SPY" => [ "etf", "500", "498", "0.40" ],
      "BTC" => [ "crypto", "90000", "91000", "-1.10" ], "NVDA" => [ "stock", "130", "125", "4.00" ]
    }.each_with_object({}) do |(sym, (kind, price, prev, pct)), h|
      a = Asset.create!(symbol: sym, name: { "AAPL" => "Apple Inc.", "MSFT" => "Microsoft", "SPY" => "SPDR S&P 500 ETF", "BTC" => "Bitcoin", "NVDA" => "NVIDIA" }[sym],
                        kind: kind, provider_ref: sym, sector: Asset.sector_for(Asset.new(symbol: sym, kind: kind)))
      Quote.create!(asset: a, price: BigDecimal(price), previous_close: BigDecimal(prev), change_percent: BigDecimal(pct), as_of: Clock.now, fetched_at: Clock.now)
      h[sym] = a
    end
  end

  def warm!(symbol, volume:, high: "200.00", low: "50.00", spark: %w[1.0 2.0], c1m: "5.00")
    Rails.cache.write(format(MarketData::Warm::KEY, symbol),
      { "spark" => spark, "week52_high" => high, "week52_low" => low, "volume" => volume, "avg_volume" => volume, "change_1m_percent" => c1m, "change_1y_percent" => "10.00" })
  end

  describe "candles" do
    before { with_asset(symbol: "AAPL"); sign_up! }

    it "adds volume per candle as an integer string, or null when Yahoo has none [DAT-01]" do
      stub_request(:get, /yahoo/).to_return(body: candle_body)
      api(:get, "/assets/AAPL/candles?range=1M")
      expect(json[:candles].map { |c| c[:volume] }).to eq(%w[1000 2500])
      Rails.cache.clear
      stub_request(:get, /yahoo/).to_return(body: candle_body(volume: nil))
      api(:get, "/assets/AAPL/candles?range=1M")
      expect(json[:candles].map { |c| c[:volume] }).to eq([ nil, nil ])
    end

    it "accepts 6M and ALL and reports the interval used [DAT-02]" do
      stub = stub_request(:get, /yahoo/).to_return(body: candle_body)
      { "6M" => "1d", "ALL" => "1w", "1D" => "5m", "1W" => "1h", "5Y" => "1w" }.each do |range, interval|
        api(:get, "/assets/AAPL/candles?range=#{range}")
        expect(response).to have_http_status(:ok), range
        expect(json).to include(range: range, interval: interval)
      end
      expect(stub).to have_been_requested.times(5)
      expect(WebMock).to have_requested(:get, /interval=1wk&range=max/)
      expect(WebMock).to have_requested(:get, /interval=1d&range=6mo/)
    end

    it "validates the range/interval combinations and answers 422 validation_failed otherwise [DAT-02]" do
      stub_request(:get, /yahoo/).to_return(body: candle_body)
      MarketData::VALID_INTERVALS.each do |range, ok|
        (MarketData::INTERVALS - ok).each do |bad|
          api(:get, "/assets/AAPL/candles?range=#{range}&interval=#{bad}")
          expect([ response.status, json[:error][:code] ]).to eq([ 422, "validation_failed" ]), "#{range}/#{bad}"
        end
        ok.each do |good|
          api(:get, "/assets/AAPL/candles?range=#{range}&interval=#{good}")
          expect(response).to have_http_status(:ok), "#{range}/#{good}"
        end
      end
      api(:get, "/assets/AAPL/candles?range=1M&interval=5m")
      expect(response).to have_http_status(422)
      api(:get, "/assets/AAPL/candles?range=1M&interval=2d")
      expect(response).to have_http_status(422)
    end

    it "caches candles per symbol, range and interval [DAT-02]" do
      stub = stub_request(:get, /yahoo/).to_return(body: candle_body)
      3.times { api(:get, "/assets/AAPL/candles?range=3M&interval=1d") }
      expect(stub).to have_been_requested.once
      api(:get, "/assets/AAPL/candles?range=3M&interval=1w")
      expect(stub).to have_been_requested.twice
    end
  end

  describe "key numbers" do
    it "parses the stats a Yahoo quote already carries without an extra request [DAT-03]" do
      stock = Asset.create!(symbol: "AAPL", name: "Apple", kind: "stock", provider_ref: "AAPL")
      body = { chart: { result: [ { meta: { regularMarketPrice: 217.62, previousClose: 213.65, regularMarketTime: 1_772_000_000, regularMarketDayHigh: 218.4,
                                           regularMarketDayLow: 212.9, regularMarketVolume: 61_200_000, fiftyTwoWeekHigh: 221.03, fiftyTwoWeekLow: 164.08 },
                                     indicators: { quote: [ { open: [ 214.1 ] } ] } } ] } }.to_json
      stub = stub_request(:get, /yahoo/).to_return(body: body)
      stats = MarketData::YahooProvider.new.quote(stock).stats
      expect(stats).to eq("day_high" => "218.4", "day_low" => "212.9", "week52_high" => "221.03", "week52_low" => "164.08",
                          "volume" => "61200000", "open" => "214.1")
      expect(stub).to have_been_requested.once
    end

    it "serves stats on the asset page from the quote and the warm cache, null when unknown [DAT-03]" do
      a = with_asset(symbol: "AAPL", price: "217.62")
      a.quote.update!(stats: { "open" => "214.10", "day_high" => "218.40", "volume" => "61200000" }, fetched_at: Clock.now)
      warm!("AAPL", volume: "54800000", high: "221.03", low: "164.08")
      sign_up!
      api(:get, "/assets/AAPL")
      expect(json[:stats]).to eq(open: "214.10000000", day_low: nil, day_high: "218.40000000", week52_low: "164.08000000", week52_high: "221.03000000",
                                 volume: "61200000", avg_volume: "54800000", change_1m_percent: "5.00", change_1y_percent: "10.00")
      expect(json[:sector]).to be_nil
      b = with_asset(symbol: "ZZZ")
      b.quote.update!(fetched_at: Clock.now)
      api(:get, "/assets/ZZZ")
      expect(json[:stats].values.compact).to be_empty
    end
  end

  describe "sector" do
    it "assigns a sector to every asset in the seeded universe [DAT-04]" do
      universe = File.read(Rails.root.join("db/seeds.rb")).scan(/\[ "([A-Z.]+)", "[^"]+", "(stock|etf|crypto)", "[^"]+" \]/)
      expect(universe.size).to be > 50
      missing = universe.reject { |sym, kind| Asset.sector_for(Asset.new(symbol: sym, kind: kind)) }
      expect(missing).to be_empty
      expect(Asset.sector_for(Asset.new(symbol: "BTC", kind: "crypto"))).to eq("Crypto")
    end

    it "is exposed on assets and filterable on the list [DAT-04, DAT-05]" do
      seed_universe
      sign_up!
      api(:get, "/assets/AAPL")
      expect(json[:sector]).to eq("Technology")
      api(:get, "/assets?sector=Crypto")
      expect(json[:assets].map { |a| a[:symbol] }).to eq([ "BTC" ])
      expect(json[:meta][:sectors]).to include("Technology", "Crypto", "Index funds")
      api(:get, "/assets?sector=Nope")
      expect(response).to have_http_status(422)
    end
  end

  describe "GET /assets list" do
    before do
      seed_universe
      warm!("AAPL", volume: "900", high: "102.00", low: "60.00")   # price 100 -> position 0.9524
      warm!("MSFT", volume: "5000", high: "80.00", low: "35.00")
      warm!("NVDA", volume: "100", high: "300.00", low: "50.00")
      sign_up!
    end

    def symbols = json[:assets].map { |a| a[:symbol] }

    it "never calls a provider [DAT-05, DAT-06]" do
      expect(MarketData).not_to receive(:quotes)
      expect(MarketData).not_to receive(:candles)
      expect(MarketData.yahoo).not_to receive(:overview)
      api(:get, "/assets?sort=name")
      expect(response).to have_http_status(:ok)
      expect(WebMock).not_to have_requested(:any, /.*/)
    end

    it "returns row fields: change_percent, week52_position, spark, volume, watched [DAT-05]" do
      api(:get, "/assets?q=apple")
      row = json[:assets].first
      expect(row).to include(symbol: "AAPL", change_percent: "2.04", week52_position: "0.9524", spark: %w[1.0 2.0], volume: "900", watched: false)
      expect(json[:meta]).to include(total: 1, page: 1, limit: 25, fuzzy: false)
    end

    it "sorts by biggest move today by default and supports every sort [DAT-05]" do
      api(:get, "/assets"); expect(symbols).to eq(%w[NVDA MSFT AAPL BTC SPY])
      api(:get, "/assets?sort=price_asc"); expect(symbols).to eq(%w[MSFT AAPL NVDA SPY BTC])
      api(:get, "/assets?sort=price_desc"); expect(symbols).to eq(%w[BTC SPY NVDA AAPL MSFT])
      api(:get, "/assets?sort=name"); expect(symbols).to eq(%w[AAPL BTC MSFT NVDA SPY])
      api(:get, "/assets?sort=volume"); expect(symbols.first(3)).to eq(%w[MSFT AAPL NVDA])
      api(:get, "/assets?sort=change_1m"); expect(response).to have_http_status(:ok)
    end

    it "filters by kind and by each quick pick, and combines them [DAT-05]" do
      api(:get, "/assets?kind=stock"); expect(symbols).to match_array(%w[AAPL MSFT NVDA])
      api(:get, "/assets?filter=gainers"); expect(symbols).to eq(%w[NVDA AAPL SPY])
      api(:get, "/assets?filter=losers"); expect(symbols).to eq(%w[MSFT BTC])
      api(:get, "/assets?filter=under_50"); expect(symbols).to eq(%w[MSFT])
      api(:get, "/assets?filter=near_high"); expect(symbols).to eq(%w[AAPL])
      api(:get, "/assets?filter=most_traded&sort=volume"); expect(symbols.first).to eq("MSFT")
      api(:get, "/assets?filter=gainers,under_50"); expect(symbols).to be_empty
      api(:get, "/assets?filter=gainers&kind=stock"); expect(symbols).to eq(%w[NVDA AAPL])
    end

    it "'open' means crypto always and stocks only while the market is open [DAT-05]" do
      api(:get, "/assets?filter=open"); expect(symbols).to match_array(%w[AAPL MSFT NVDA SPY BTC])
      Clock.override = -> { Time.utc(2026, 3, 1, 16, 0, 0) } # Sunday
      api(:get, "/assets?filter=open"); expect(symbols).to eq(%w[BTC])
    end

    it "filters by what the user watches and owns, and counts them [DAT-05]" do
      api(:post, "/watchlist", { symbol: "MSFT" })
      Orders::Place.call(account: User.last.account, symbol: "AAPL", side: "buy", amount: "100", idempotency_key: "k1")
      api(:get, "/assets?filter=watching"); expect(symbols).to eq(%w[MSFT]); expect(json[:assets].first[:watched]).to be(true)
      api(:get, "/assets?filter=owned"); expect(symbols).to eq(%w[AAPL])
      expect(json[:meta][:counts]).to eq(all: 5, stock: 3, etf: 1, crypto: 1, watching: 1, owned: 1)
    end

    it "counts respect the search but not the kind filter [DAT-05]" do
      api(:get, "/assets?q=c&kind=crypto")
      expect(json[:meta][:counts]).to include(all: 3, crypto: 1, stock: 2, etf: 0) # Apple Inc., Microsoft, Bitcoin
      expect(symbols).to eq(%w[BTC])
      expect(json[:meta][:total]).to eq(1)
    end

    it "paginates with page and limit (max 50) and reports the total [DAT-05]" do
      api(:get, "/assets?limit=2&page=2&sort=name")
      expect(symbols).to eq(%w[MSFT NVDA])
      expect(json[:meta]).to include(total: 5, page: 2, limit: 2)
      api(:get, "/assets?limit=2&page=9"); expect(symbols).to eq([])
    end

    it "flags typo-tolerant results [DAT-05]" do
      api(:get, "/assets?q=aple")
      expect(symbols).to eq(%w[AAPL])
      expect(json[:meta][:fuzzy]).to be(true)
    end

    it "rejects invalid values with 422 validation_failed [DAT-05]" do
      %w[kind=bond filter=gainers,bogus sort=random page=0 page=x limit=0 limit=51 limit=abc].each do |qs|
        api(:get, "/assets?#{qs}")
        expect([ response.status, json[:error][:code] ]).to eq([ 422, "validation_failed" ]), qs
      end
    end
  end

  describe "warm job" do
    let!(:aapl) { Asset.create!(symbol: "AAPL", name: "Apple", kind: "stock", provider_ref: "AAPL") }
    let!(:btc) { Asset.create!(symbol: "BTC", name: "Bitcoin", kind: "crypto", provider_ref: "bitcoin") }

    def year_body
      ts = (0...40).map { |i| 1_700_000_000 + i * 86_400 }
      close = (0...40).map { |i| 100 + i }
      { chart: { result: [ { meta: { regularMarketDayHigh: 140.5, regularMarketDayLow: 130, regularMarketVolume: 777 }, timestamp: ts,
                             indicators: { quote: [ { open: close, high: close.map { |c| c + 1 }, low: close.map { |c| c - 1 }, close: close, volume: close.map { |c| c * 10 } } ] } } ] } }.to_json
    end

    it "fills spark, 52-week range, volumes and changes with one provider call per asset [DAT-06]" do
      stub = stub_request(:get, /yahoo/).to_return(body: year_body)
      expect(MarketData::Warm.call(throttle: 0)).to eq(2)
      expect(stub).to have_been_requested.times(2)
      w = MarketData::Warm.read(aapl)
      expect(w["spark"].size).to eq(30)
      expect(w["spark"].last).to eq("139.0")
      expect(w).to include("week52_high" => "140.0", "week52_low" => "99.0", "volume" => "777", "day_high" => "140.5", "open" => "139.0")
      expect(w["change_1m_percent"]).to eq("27.52") # last 139 vs the first close within 30 days (110): window math
      expect(w["change_1y_percent"]).to eq("39.0")
      expect(w["avg_volume"]).to eq("1245") # mean of the last 30 closes * 10
    end

    it "keeps the previous value when a provider call fails and never raises [DAT-06]" do
      Rails.cache.write(format(MarketData::Warm::KEY, "AAPL"), { "spark" => %w[9.0] })
      stub_request(:get, /yahoo/).to_return(status: 500)
      expect { expect(MarketData::Warm.call(throttle: 0)).to eq(0) }.not_to raise_error
      expect(MarketData::Warm.read(aapl)).to eq("spark" => %w[9.0])
      stub_request(:get, /yahoo/).to_timeout
      expect(MarketData::Warm.call(throttle: 0)).to eq(0)
      stub_request(:get, /yahoo/).to_return(body: "<html>")
      expect(MarketData::Warm.call(throttle: 0)).to eq(0)
      stub_request(:get, /yahoo/).to_return(body: { chart: { result: [ { timestamp: [], indicators: { quote: [ {} ] } } ] } }.to_json)
      expect(MarketData::Warm.call(throttle: 0)).to eq(0)
    end

    it "is scheduled hourly in config/recurring.yml and runs as a job [DAT-06]" do
      yml = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result, aliases: true)
      expect(yml["production"]["warm_market_data"]).to include("class" => "WarmMarketDataJob", "schedule" => a_string_matching(/every hour/))
      allow(MarketData::Warm).to receive(:call).and_return(1)
      WarmMarketDataJob.perform_now
      expect(MarketData::Warm).to have_received(:call)
    end

    it "throttles between assets [DAT-06]" do
      stub_request(:get, /yahoo/).to_return(body: year_body)
      warm = MarketData::Warm.new(throttle: 0.5)
      allow(warm).to receive(:sleep)
      warm.call
      expect(warm).to have_received(:sleep).with(0.5).once
    end
  end

  describe "orders for chart markers" do
    it "filters by status and accepts limit up to 200 [DAT-07]" do
      with_asset(symbol: "AAPL")
      sign_up!
      acct = User.last.account
      Orders::Place.call(account: acct, symbol: "AAPL", side: "buy", amount: "100", idempotency_key: "a")
      Orders::Place.call(account: acct, symbol: "AAPL", side: "buy", amount: "50", idempotency_key: "b")
      api(:get, "/orders?symbol=AAPL&status=filled&limit=200")
      expect(json[:orders].size).to eq(2)
      expect(json[:orders].first).to include(side: "buy", status: "filled")
      expect(json[:orders].first.keys).to include(:quantity, :price, :filled_at)
      expect(json[:per_page]).to eq(200)
      api(:get, "/orders?status=pending"); expect(json[:orders]).to be_empty
      api(:get, "/orders?limit=1"); expect(json[:orders].size).to eq(1)
      %w[status=bogus limit=0 limit=201].each { |qs| api(:get, "/orders?#{qs}"); expect(response).to have_http_status(422), qs }
    end
  end

  describe "GET /market/overview" do
    it "returns S&P 500, Nasdaq and Bitcoin from cached quotes, without auth, omitting missing quotes [DAT-08]" do
      with_asset(symbol: "SPY", price: "600").quote.update!(change_percent: BigDecimal("0.4"))
      with_asset(symbol: "BTC", kind: "crypto", price: "90000").quote.update!(change_percent: BigDecimal("-0.9"))
      api(:get, "/market/overview")
      expect(response).to have_http_status(:ok)
      expect(json[:items]).to eq([
        { symbol: "SPY", label: "S&P 500", price: "600.00000000", change_percent: "0.40", proxy_for: "SPY" },
        { symbol: "BTC", label: "Bitcoin", price: "90000.00000000", change_percent: "-0.90", proxy_for: nil }
      ])
      expect(WebMock).not_to have_requested(:any, /.*/)
    end

    it "caches for 60 seconds [DAT-08]" do
      spy = with_asset(symbol: "SPY", price: "600")
      api(:get, "/market/overview")
      spy.quote.update!(price: BigDecimal("700"))
      api(:get, "/market/overview")
      expect(json[:items].first[:price]).to eq("600.00000000")
      Rails.cache.clear
      api(:get, "/market/overview")
      expect(json[:items].first[:price]).to eq("700.00000000")
    end

    it "is empty rather than an error when no quotes exist [DAT-08]" do
      api(:get, "/market/overview")
      expect(json).to eq(items: [])
    end
  end

  it "supports a 3M range on portfolio history for the Home chart tabs [HOME-04]" do
    sign_up!
    api(:get, "/portfolio/history?range=3M")
    expect(response).to have_http_status(:ok)
    expect(json[:range]).to eq("3M")
  end

  it "keeps the OpenAPI contract documenting every v3 endpoint and parameter [QA-01]" do
    spec = YAML.load_file(Rails.root.join("openapi.yml"))
    expect(spec["paths"].keys).to include("/market/overview")
    params = spec["paths"]["/assets"]["get"]["parameters"].map { |p| p["name"] }
    expect(params).to include("kind", "filter", "sector", "sort", "page", "limit", "q")
    expect(spec["paths"]["/assets/{symbol}/candles"]["get"]["parameters"].map { |p| p["name"] }).to include("interval")
  end
end
