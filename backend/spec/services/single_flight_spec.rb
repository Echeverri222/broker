require "rails_helper"

# Real threads and DB connections: no transactional fixtures here.
RSpec.describe MarketData::SingleFlight do
  self.use_transactional_tests = false

  it "runs the fetch once when 12 threads miss the same key at the same time [MKD-07]" do
    calls = Concurrent::AtomicFixnum.new(0)
    results = Array.new(12)
    threads = Array.new(12) do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          results[i] = described_class.fetch("sf/test", expires_in: 1.minute) { calls.increment; sleep 0.2; [ 1, 2, 3 ] }
        end
      end
    end
    threads.each(&:join)
    expect(calls.value).to eq(1)
    expect(results).to all(eq([ 1, 2, 3 ]))
  end

  it "does not hold the lock after the block raises, so the next caller can try [MKD-07]" do
    expect { described_class.fetch("sf/raise", expires_in: 1.minute) { raise MarketData::ProviderError, "boom" } }.to raise_error(MarketData::ProviderError)
    expect(described_class.fetch("sf/raise", expires_in: 1.minute) { :ok }).to eq(:ok)
  end

  it "serves candles through it, so concurrent cold misses make one Yahoo call [MKD-07]" do
    asset = Asset.create!(symbol: "SFX", name: "x", kind: "stock", provider_ref: "SFX")
    body = { chart: { result: [ { timestamp: [ 1_772_000_000 ], indicators: { quote: [ { open: [ 1 ], high: [ 2 ], low: [ 1 ], close: [ 2 ], volume: [ 5 ] } ] } } ] } }.to_json
    stub = stub_request(:get, /yahoo/).to_return { sleep 0.2; { body: body } }
    threads = Array.new(6) { Thread.new { ActiveRecord::Base.connection_pool.with_connection { MarketData.candles(asset, range: "1M", interval: "1d") } } }
    threads.each(&:join)
    expect(stub).to have_been_requested.once
  ensure
    Asset.where(symbol: "SFX").delete_all
  end
end
