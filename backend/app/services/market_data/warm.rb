module MarketData
  # DAT-06: fills the cache the Markets list reads (sparkline, 52-week range, volume, 1M/1Y change).
  # At most one provider call per asset per run, throttled, and failure-tolerant: a failing asset keeps its
  # previous cached value and the run never raises.
  class Warm
    KEY = "warm/v1/%s".freeze
    TTL = 2.days

    def self.call(**kw) = new(**kw).call
    def self.read(asset) = Rails.cache.read(format(KEY, asset.symbol)) || {}

    def initialize(throttle: 0.25, assets: Asset.active)
      @throttle = throttle
      @assets = assets
    end

    # Returns the number of assets refreshed.
    def call
      ok = 0
      @assets.find_each.with_index do |asset, i|
        sleep(@throttle) if i.positive? && @throttle.positive?
        data = MarketData.yahoo.overview(asset)
        Rails.cache.write(format(KEY, asset.symbol), data, expires_in: TTL)
        ok += 1
      rescue StandardError => e # ProviderError, parsing surprises: keep the previous value
        Rails.logger.warn("warm #{asset.symbol}: #{e.class}: #{e.message}")
      end
      ok
    rescue StandardError => e
      Rails.logger.error("warm run failed: #{e.class}: #{e.message}")
      0
    end
  end
end
