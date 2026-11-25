require "rails_helper"

# PRD v4 §5 (MKD): the request path never calls a provider; jobs own provider traffic.
RSpec.describe "Market data isolation [MKD]" do
  let(:open_t) { BrokerHelpers::OPEN_TIME }
  before { Clock.override = -> { open_t } }

  describe "request path" do
    # A plain integration session: these examples assert on provider traffic, not on the OpenAPI contract.
    let(:session) { ActionDispatch::Integration::Session.new(Rails.application) }

    def call_api(method, path, body = nil)
      session.send(method, "/api/v1#{path}", params: body&.to_json, headers: ApiHelpers::JSON_HEADERS)
    end

    before do
      stub_request(:any, /yahoo|coingecko/).to_raise("provider must not be called from a request")
      call_api(:post, "/signup", { name: "T", email: "mkd@example.com", password: "password123" })
      expect(session.response.status).to eq(201)
    end

    it "GET /assets/:symbol returns the stored quote and never calls a provider [MKD-01]" do
      with_asset(symbol: "AAPL", price: "100", fetched_at: open_t - 10.minutes)
      call_api(:get, "/assets/AAPL")
      body = JSON.parse(session.response.body)
      expect(session.response.status).to eq(200)
      expect(body.dig("quote", "price")).to eq("100.00000000")
      expect(WebMock).not_to have_requested(:any, /.*/)
    end

    it "asks for exactly one background refresh, however many requests arrive [MKD-01, MKD-02]" do
      with_asset(symbol: "AAPL", price: "100", fetched_at: open_t - 10.minutes)
      expect { 5.times { call_api(:get, "/assets/AAPL") } }.to have_enqueued_job(RefreshAssetJob).exactly(:once)
    end

    it "asks again once the coalescing window has passed [MKD-02]" do
      with_asset(symbol: "AAPL", price: "100", fetched_at: open_t - 10.minutes)
      expect { call_api(:get, "/assets/AAPL") }.to have_enqueued_job(RefreshAssetJob).once
      Clock.override = -> { open_t + 31.seconds }
      Rails.cache.delete("refresh_claim/#{Asset.find_by!(symbol: 'AAPL').id}") # memory store ignores the Clock seam
      expect { call_api(:get, "/assets/AAPL") }.to have_enqueued_job(RefreshAssetJob).once
    end

    it "does not refresh at all while the quote is fresh [MKD-01]" do
      with_asset(symbol: "AAPL", price: "100")
      expect { call_api(:get, "/assets/AAPL") }.not_to have_enqueued_job(RefreshAssetJob)
    end

    it "flags a stale quote so the UI shows 'Delayed' and trading stays off [MKD-01, UX-05]" do
      with_asset(symbol: "AAPL", price: "100", as_of: open_t - 10.minutes, fetched_at: open_t - 10.minutes)
      call_api(:get, "/assets/AAPL")
      expect(JSON.parse(session.response.body).dig("quote", "stale")).to be(true)
    end
  end

  describe "the refresh job" do
    it "fetches one asset and keeps the old quote when the provider fails [MKD-01]" do
      asset = with_asset(symbol: "AAPL", price: "100", fetched_at: open_t - 10.minutes)
      allow(MarketData).to receive(:quotes).and_raise(MarketData::ProviderError, "down")
      expect(Quotes::Refresh.refresh_asset(asset).price).to eq(100)

      fresh = MarketData::Quote.new(price: BigDecimal("101"), previous_close: BigDecimal("100"), change: 1, change_percent: 1, as_of: open_t)
      allow(MarketData).to receive(:quotes).and_return({ asset.id => fresh })
      RefreshAssetJob.perform_now(asset.id)
      expect(asset.reload.quote).to have_attributes(price: 101, fetched_at: open_t)
    end

    it "runs on the critical queue [JOB-01]" do
      expect(RefreshAssetJob.new.queue_name).to eq("critical")
    end
  end

  describe "background refresh" do
    it "fetches all cryptos with ONE provider call per run [MKD-04]" do
      %w[bitcoin ethereum solana].each { |ref| Asset.create!(symbol: ref[0, 3].upcase, name: ref, kind: "crypto", provider_ref: ref) }
      body = %w[bitcoin ethereum solana].to_h { |r| [ r, { usd: 10, usd_24h_change: 1, last_updated_at: open_t.to_i } ] }.to_json
      stub = stub_request(:get, /coingecko/).to_return(body: body)
      Quotes::Refresh.call(force: true)
      expect(stub).to have_been_requested.once
      expect(Quote.count).to eq(3)
    end

    it "treats assets with waiting orders as priority, so the open-time fill has a fresh price [MKD-05]" do
      user = create(:user)
      Clock.override = -> { Time.utc(2026, 3, 7, 16, 0, 0) } # Saturday: the order queues
      asset = with_asset(symbol: "AAPL", price: "100")
      Orders::Place.call(account: user.account, symbol: "AAPL", side: "buy", amount: "50", idempotency_key: "w1")
      expect(Quotes::Refresh.new.send(:priority_asset_ids)).to include(asset.id)
    end
  end

  describe "PreOpenRefreshJob" do
    it "refreshes only the assets that have a waiting order, once each [MKD-05]" do
      user = create(:user)
      Clock.override = -> { Time.utc(2026, 3, 7, 16, 0, 0) }
      a = with_asset(symbol: "AAPL", price: "100")
      b = with_asset(symbol: "MSFT", price: "100")
      with_asset(symbol: "IDLE", price: "100")
      %w[k1 k2].each { |k| Orders::Place.call(account: user.account, symbol: "AAPL", side: "buy", amount: "10", idempotency_key: k) }
      Orders::Place.call(account: user.account, symbol: "MSFT", side: "buy", amount: "10", idempotency_key: "k3")

      asked = []
      allow(MarketData).to receive(:quotes) { |assets| asked.concat(assets.map(&:symbol)); {} }
      expect(PreOpenRefreshJob.perform_now).to eq(2)
      expect(asked).to contain_exactly("AAPL", "MSFT")
      expect(PreOpenRefreshJob.new.queue_name).to eq("critical")
      expect([ a, b ]).to all(be_persisted)
    end

    it "is scheduled for 9:29 ET on weekdays [MKD-05]" do
      yml = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result, aliases: true)
      expect(yml["production"]["pre_open_refresh"]).to include("class" => "PreOpenRefreshJob", "schedule" => "every weekday at 9:29am America/New_York")
    end
  end

  describe "Gateway [MKD-06]" do
    let(:stock) { Asset.create!(symbol: "AAPL", name: "Apple", kind: "stock", provider_ref: "AAPL") }
    let(:yahoo) { MarketData::YahooProvider.new }

    it "opens the circuit after 5 failures and stops calling the provider" do
      stub = stub_request(:get, /yahoo/).to_return(status: 500)
      5.times { expect { yahoo.quote(stock) }.to raise_error(MarketData::ProviderError, /responded 500/) }
      expect(MarketData::Gateway.state("yahoo")).to eq("open")
      expect { yahoo.quote(stock) }.to raise_error(MarketData::ProviderError, /circuit open/)
      expect(stub).to have_been_requested.times(5)
    end

    it "probes again after 30 seconds and closes on success" do
      stub_request(:get, /yahoo/).to_return(status: 500)
      5.times { yahoo.quote(stock) rescue nil }
      Clock.override = -> { open_t + 31.seconds }
      expect(MarketData::Gateway.state("yahoo")).to eq("half_open")
      stub_request(:get, /yahoo/).to_return(body: { chart: { result: [ { meta: { regularMarketPrice: 10, previousClose: 9, regularMarketTime: open_t.to_i } } ] } }.to_json)
      expect(yahoo.quote(stock).price).to eq(10)
      expect(MarketData::Gateway.state("yahoo")).to eq("closed")
    end

    it "re-opens immediately when the probe fails" do
      stub_request(:get, /yahoo/).to_return(status: 500)
      5.times { yahoo.quote(stock) rescue nil }
      Clock.override = -> { open_t + 31.seconds }
      expect { yahoo.quote(stock) }.to raise_error(MarketData::ProviderError, /responded 500/)
      expect(MarketData::Gateway.state("yahoo")).to eq("open")
    end

    it "enforces a per-provider calls-per-minute budget and never exceeds it" do
      stub = stub_request(:get, /yahoo/).to_return(body: { chart: { result: [ { meta: { regularMarketPrice: 10, previousClose: 9, regularMarketTime: open_t.to_i } } ] } }.to_json)
      with_env("YAHOO_MAX_PER_MIN" => "3") do
        3.times { yahoo.quote(stock) }
        expect { yahoo.quote(stock) }.to raise_error(MarketData::ProviderError, /budget of 3\/min/)
        expect(stub).to have_been_requested.times(3)
        expect(MarketData::Gateway.calls_this_minute("yahoo")).to be >= 3
        Clock.override = -> { open_t + 61.seconds } # next minute: budget resets
        expect(yahoo.quote(stock).price).to eq(10)
      end
    end

    it "keeps separate state per provider" do
      stub_request(:get, /yahoo/).to_return(status: 500)
      5.times { yahoo.quote(stock) rescue nil }
      expect(MarketData::Gateway.state("coingecko")).to eq("closed")
    end

    def with_env(vars)
      old = vars.to_h { |k, _| [ k, ENV[k] ] }
      vars.each { |k, v| ENV[k] = v }
      yield
    ensure
      old.each { |k, v| ENV[k] = v }
    end
  end
end
