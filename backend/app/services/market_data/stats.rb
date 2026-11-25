module MarketData
  # DAT-03: key numbers for an asset. Quote-time values (cached with the quote) win; the hourly warm cache fills
  # the rest (52-week range and volumes for crypto, average volume, 1 month and 1 year change). Never calls a provider.
  class Stats
    KEYS = %w[open day_low day_high week52_low week52_high volume avg_volume change_1m_percent change_1y_percent].freeze

    def self.for(asset) = new(asset).to_h

    def initialize(asset)
      @quote_stats = asset.quote&.stats || {}
      @warm = Warm.read(asset)
      @price = asset.quote&.price
    end

    def to_h = KEYS.to_h { |k| [ k, value(k) ] }

    def spark = @warm["spark"]

    # Where the price sits in its 52-week range, 0..1 (a ratio, not money).
    def week52_position
      lo, hi = value("week52_low"), value("week52_high")
      return nil unless lo && hi && @price && hi > lo
      ((@price - lo) / (hi - lo)).clamp(0, 1).round(4)
    end

    def volume = value("volume")

    private

    def value(key)
      v = @quote_stats[key] || @warm[key]
      v && BigDecimal(v)
    end
  end
end
