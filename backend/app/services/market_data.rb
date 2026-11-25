# Single entry point for market data. Real providers only:
#   - Yahoo Finance chart endpoint (unofficial, no key): stock/ETF quotes, and candles for everything
#   - CoinGecko public API: crypto quotes (one batch call)
# Swap or add providers here without touching the rest of the app.
module MarketData
  # `stats` (optional) is a Hash of decimal strings cached with the quote (DAT-03).
  Quote  = Struct.new(:price, :previous_close, :change, :change_percent, :as_of, :stats, keyword_init: true)
  # `volume` is an Integer, or nil when the provider has none for that candle (DAT-01).
  Candle = Struct.new(:time, :open, :high, :low, :close, :volume, keyword_init: true)

  class ProviderError < StandardError; end

  RANGES = %w[1D 1W 1M 3M 6M 1Y 5Y ALL].freeze
  INTERVALS = %w[1h 1d 1w].freeze
  # DAT-02: valid candle sizes per range, and the default used when `interval` is omitted.
  # 1D defaults to 5-minute candles (a finer picture of one day than hourly); "1h" can still be asked for.
  VALID_INTERVALS = {
    "1D" => %w[1h], "1W" => %w[1h 1d], "1M" => %w[1d], "3M" => %w[1d 1w], "6M" => %w[1d 1w],
    "1Y" => %w[1d 1w], "5Y" => %w[1d 1w], "ALL" => %w[1w]
  }.freeze
  DEFAULT_INTERVALS = {
    "1D" => "5m", "1W" => "1h", "1M" => "1d", "3M" => "1d", "6M" => "1d", "1Y" => "1d", "5Y" => "1w", "ALL" => "1w"
  }.freeze

  class << self
    attr_writer :yahoo, :coingecko

    def yahoo = (@yahoo ||= YahooProvider.new)
    def coingecko = (@coingecko ||= CoingeckoProvider.new)

    def quote(asset)
      asset.crypto? ? coingecko.quotes([ asset ]).fetch(asset.id) : yahoo.quote(asset)
    rescue KeyError
      raise ProviderError, "no quote for #{asset.symbol}"
    end

    # Batch; assets whose lookup fails are omitted (the caller keeps the previous quote).
    def quotes(assets)
      crypto, equities = assets.partition(&:crypto?)
      result = {}
      result.merge!(coingecko.quotes(crypto)) if crypto.any?
      result.merge!(yahoo.quotes(equities)) if equities.any?
      result
    end

    # Returns the effective interval for a range, or raises ArgumentError for an invalid combination (DAT-02).
    def interval_for(range, interval)
      return DEFAULT_INTERVALS.fetch(range) if interval.blank?
      raise ArgumentError, "interval must be one of #{INTERVALS.join(', ')}" unless INTERVALS.include?(interval)
      unless VALID_INTERVALS.fetch(range).include?(interval)
        raise ArgumentError, "#{interval} candles are not available for #{range}. Try #{VALID_INTERVALS.fetch(range).join(' or ')}."
      end
      interval
    end

    # Candles are cached per (symbol, range, interval): 5 min for intraday ranges, 1 h for daily+ ranges.
    # `interval` must already be effective (see interval_for); nil means the range default.
    def candles(asset, range:, interval: nil)
      interval ||= DEFAULT_INTERVALS.fetch(range)
      ttl = %w[1D 1W].include?(range) ? 5.minutes : 1.hour
      SingleFlight.fetch("candles/v3/#{asset.symbol}/#{range}/#{interval}", expires_in: ttl) do
        yahoo.candles(asset, range: range, interval: interval).map(&:to_h)
      end.map { |h| Candle.new(**h.symbolize_keys) }
    end

    # Close series [[unix_time, BigDecimal]] from `from` to now, for benchmark maths.
    def history(asset, from:)
      day = from.to_date
      SingleFlight.fetch("history/v1/#{asset.symbol}/#{day}", expires_in: 10.minutes) do
        yahoo.history(asset, from: day.in_time_zone("UTC") - 7.days).map { |t, c| [ t, c.to_s ] }
      end.map { |t, c| [ t, BigDecimal(c) ] }
    end

    def splits(asset, from:) = yahoo.splits(asset, from: from)

    def market_status = MarketCalendar.status
  end
end
