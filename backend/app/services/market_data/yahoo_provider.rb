module MarketData
  # Yahoo Finance public chart endpoint. Unofficial and without an SLA: fine for a
  # prototype, replace with a licensed feed before any public launch.
  class YahooProvider
    include Http
    BASE = "https://query1.finance.yahoo.com/v8/finance/chart".freeze
    RANGES = { # our range => yahoo range
      "1D" => "1d", "1W" => "5d", "1M" => "1mo", "3M" => "3mo", "6M" => "6mo", "1Y" => "1y", "5Y" => "5y", "ALL" => "max"
    }.freeze
    INTERVALS = { "5m" => "5m", "1h" => "1h", "1d" => "1d", "1w" => "1wk" }.freeze
    STAT_META = { "day_high" => "regularMarketDayHigh", "day_low" => "regularMarketDayLow",
                  "week52_high" => "fiftyTwoWeekHigh", "week52_low" => "fiftyTwoWeekLow" }.freeze
    THREADS = 4

    def yahoo_symbol(asset) = asset.crypto? ? "#{asset.symbol}-USD" : asset.provider_ref

    # MKT-02: any missing/null/non-positive field raises ProviderError; never returns 0 or nil as a price.
    def quote(asset)
      result = chart(yahoo_symbol(asset), "range=1d&interval=1d")
      meta = result["meta"]
      raise ProviderError, "yahoo: missing meta for #{asset.symbol}" unless meta.is_a?(Hash)
      price = decimal_field(meta["regularMarketPrice"], "price", asset)
      raise ProviderError, "yahoo: non-positive price for #{asset.symbol}" unless price.positive?
      raise ProviderError, "yahoo: missing time for #{asset.symbol}" unless meta["regularMarketTime"].is_a?(Integer)
      prev = meta["previousClose"] || meta["chartPreviousClose"]
      prev = prev && decimal_field(prev, "previous close", asset)
      change = prev ? price - prev : 0.to_d
      MarketData::Quote.new(price: price, previous_close: prev, change: change,
                            change_percent: prev&.nonzero? ? (change / prev * 100).round(4) : 0,
                            as_of: Time.at(meta["regularMarketTime"]).utc, stats: quote_stats(meta, result))
    end

    # DAT-06: one chart call (1 year of daily candles) per asset yields everything the Markets list and the key
    # numbers need that a quote does not carry. Values are decimal strings; any may be absent.
    def overview(asset)
      result = chart(yahoo_symbol(asset), "range=1y&interval=1d")
      candles = parse_candles(result)
      raise ProviderError, "yahoo: no daily history for #{asset.symbol}" if candles.empty?
      last = candles.last
      month_ago = candles.find { |c| c.time >= last.time - 30.days.to_i } || candles.first
      volumes = candles.last(30).filter_map(&:volume)
      meta = result["meta"].is_a?(Hash) ? result["meta"] : {}
      {
        "spark" => candles.last(30).map { |c| c.close.to_s("F") },
        "week52_high" => candles.map(&:high).max.to_s("F"), "week52_low" => candles.map(&:low).min.to_s("F"),
        "volume" => (meta["regularMarketVolume"].is_a?(Numeric) ? meta["regularMarketVolume"] : last.volume)&.to_i&.to_s,
        "avg_volume" => volumes.empty? ? nil : (volumes.sum / volumes.size).to_s,
        "open" => last.open.to_s("F"),
        "day_high" => num_str(meta["regularMarketDayHigh"]), "day_low" => num_str(meta["regularMarketDayLow"]),
        "change_1m_percent" => change_pct(last.close, month_ago.close), "change_1y_percent" => change_pct(last.close, candles.first.close)
      }.compact
    end

    # Split events since `from`: [[Date, BigDecimal ratio]] (ratio 2 = 2-for-1, 0.1 = 1-for-10).
    def splits(asset, from:)
      result = chart(yahoo_symbol(asset), "period1=#{from.to_i}&period2=#{Clock.now.to_i}&interval=1d&events=split")
      (result.dig("events", "splits") || {}).values.map do |e|
        num, den = e["numerator"], e["denominator"]
        raise ProviderError, "yahoo: malformed split" unless num.is_a?(Numeric) && den.is_a?(Numeric) && num.positive? && den.positive?
        [ Time.at(e["date"]).utc.in_time_zone(MarketCalendar::ZONE).to_date, BigDecimal(num.to_s) / BigDecimal(den.to_s) ]
      end
    end

    def quotes(assets)
      queue = Queue.new
      assets.each { |a| queue << a }
      out = {}
      lock = Mutex.new
      Array.new([ THREADS, assets.size ].min) do
        Thread.new do
          while (a = (queue.pop(true) rescue nil))
            begin
              q = quote(a)
              lock.synchronize { out[a.id] = q }
            rescue ProviderError => e
              Rails.logger.warn("yahoo quote #{a.symbol}: #{e.message}")
            end
          end
        end
      end.each(&:join)
      out.to_h
    end

    def candles(asset, range:, interval:)
      parse_candles(chart(yahoo_symbol(asset), "range=#{RANGES.fetch(range)}&interval=#{INTERVALS.fetch(interval)}"))
    end

    def history(asset, from:)
      span = (Clock.now - from) / 1.day
      interval = span <= 700 ? "1h" : "1d"
      data = chart(yahoo_symbol(asset), "period1=#{from.to_i}&period2=#{Clock.now.to_i}&interval=#{interval}")
      parse_candles(data).map { |c| [ c.time, c.close ] }
    end

    private

    def num_str(v) = v.is_a?(Numeric) && v.positive? ? v.to_d.to_s("F") : nil

    def change_pct(now, then_)
      then_.positive? ? ((now - then_) / then_ * 100).round(2).to_s("F") : nil
    end

    # DAT-03: whatever the quote call already carries, no extra request. Anything missing is simply left out.
    def quote_stats(meta, result)
      stats = STAT_META.to_h { |k, m| [ k, num_str(meta[m]) ] }
      stats["volume"] = meta["regularMarketVolume"].is_a?(Numeric) ? meta["regularMarketVolume"].to_i.to_s : nil
      stats["open"] = num_str(result.dig("indicators", "quote", 0, "open")&.first)
      stats.compact
    end

    def decimal_field(value, name, asset)
      raise ProviderError, "yahoo: missing #{name} for #{asset.symbol}" unless value.is_a?(Numeric)
      value.to_d
    end

    def chart(symbol, params)
      body = get_json("#{BASE}/#{ERB::Util.url_encode(symbol)}?#{params}")
      result = body.dig("chart", "result", 0) or raise ProviderError, "yahoo: #{body.dig('chart', 'error', 'description') || 'empty result'}"
      result
    end

    def parse_candles(result)
      ts = result["timestamp"] || []
      q = result.dig("indicators", "quote", 0) || {}
      ts.each_with_index.filter_map do |t, i|
        close = q["close"]&.[](i)
        next unless close
        vol = q["volume"]&.[](i)
        MarketData::Candle.new(time: t, open: (q["open"]&.[](i) || close).to_d, high: (q["high"]&.[](i) || close).to_d,
                               low: (q["low"]&.[](i) || close).to_d, close: close.to_d, volume: vol.is_a?(Numeric) ? vol.to_i : nil)
      end
    end
  end
end
