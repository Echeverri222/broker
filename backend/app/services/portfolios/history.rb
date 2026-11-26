module Portfolios
  # PERF-04..08: value series, range return (excluding deposits) and the optional SPY benchmark.
  class History
    MAX_POINTS = 600 # SCL-09
    RANGES = { "1D" => 1.day, "1W" => 7.days, "1M" => 30.days, "3M" => 90.days, "1Y" => 365.days, "ALL" => nil }.freeze

    def self.call(account, range:, benchmark: false, now: Clock.now) = new(account, range, benchmark, now).call

    def initialize(account, range, benchmark, now)
      @account, @range, @benchmark, @now = account, range, benchmark, now
    end

    def call
      raise ApiError.new(:validation_failed, "range must be one of #{RANGES.keys.join(', ')}") unless RANGES.key?(@range)
      range_start = RANGES[@range] && @now - RANGES[@range]
      v = Valuate.call(@account)
      in_range = @account.portfolio_snapshots.where(range_start ? [ "taken_at >= ?", range_start ] : nil).order(:taken_at, :id).to_a
      start = range_start && @account.portfolio_snapshots.where("taken_at <= ?", range_start).order(:taken_at, :id).last
      start ||= in_range.first

      series = (in_range.map { |s| [ s.taken_at, s.total_value ] } + [ [ @now, v.total_value ] ])
      series = series.sort_by(&:first).each_with_object({}) { |(t, val), h| h[t.to_i] = [ t, val ] }.values # PERF-06: unique timestamps
      series = self.class.downsample(series, MAX_POINTS) # SCL-09: the benchmark below reuses exactly these times
      points = series.map { |t, val| { time: Fmt.iso(t), value: Fmt.money(val) } }

      body = range_return(start, v).merge(range: @range, series: points)
      body[:incomplete] = v.incomplete
      attach_benchmark(body, series) if @benchmark
      body
    end

    # SCL-09: at most `max` points. The first and last point are always kept; between them every bucket keeps its lowest
    # and highest value, so peaks and drawdowns survive. Input is sorted by time, output too.
    def self.downsample(series, max)
      return series if series.size <= max
      inner = series[1..-2]
      buckets = (max - 2) / 2
      size = (inner.size + buckets - 1) / buckets # integer ceiling (MON-01: no floats here)
      kept = inner.each_slice(size).flat_map do |slice|
        [ slice.min_by { |_, v| v }, slice.max_by { |_, v| v } ].uniq
      end
      [ series.first, *kept.sort_by { |t, _| t }, series.last ]
    end

    private

    # PERF-04
    def range_return(start, valuation)
      return { deposits_in_range: Fmt.money(0), return: Fmt.money(0), return_percent: Fmt.dec(0, 2) } unless start
      deposited = @account.deposits.where("created_at > ?", start.taken_at).sum(:amount)
      gain = valuation.total_value - start.total_value - deposited
      base = start.total_value + deposited
      { deposits_in_range: Fmt.money(deposited), return: Fmt.money(gain), return_percent: Fmt.dec(Presenters.pct(gain, base), 2) }
    end

    # PERF-07: each deposit buys SPY units at the last bar at or before it; failure degrades to benchmark: nil.
    def attach_benchmark(body, series)
      spy = Asset.find_by(symbol: "SPY") or raise ApiError.new(:not_found, "SPY is not in the asset universe")
      prices = MarketData.history(spy, from: @account.benchmark_start)
      raise MarketData::ProviderError, "SPY history is empty" if prices.empty?
      times = prices.map(&:first)
      price_at = lambda do |t|
        i = times.bsearch_index { |x| x > t.to_i }
        prices[i ? [ i - 1, 0 ].max : -1].last
      end
      lots = @account.deposits.order(:created_at).map { |d| [ d.created_at, d.amount / price_at.call(d.created_at) ] }
      points = series.map do |t, _|
        units = lots.select { |at, _| at.to_i <= t.to_i }.sum(BigDecimal("0")) { |_, u| u }
        { time: Fmt.iso(t), value: Fmt.money(units * price_at.call(t)) }
      end
      body[:benchmark] = { symbol: "SPY", series: points }
    rescue MarketData::ProviderError => e
      body[:benchmark] = nil
      body[:benchmark_error] = "SPY comparison is unavailable right now."
      Rails.logger.warn("benchmark failed: #{e.message}")
    end
  end
end
