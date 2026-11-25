module Quotes
  # Refreshes the `quotes` table. Crypto every minute; equities every minute
  # during market hours if held / watched / recently viewed, else every 15 min.
  # Uses a Postgres advisory lock so overlapping runs skip instead of piling up.
  class Refresh
    LOCK_KEY = 7_340_001
    VIEW_WINDOW = 10.minutes

    def self.call(**kw) = new(**kw).call

    def initialize(force: false)
      @force = force
    end

    def call
      conn = ActiveRecord::Base.connection
      return :skipped unless conn.select_value("SELECT pg_try_advisory_lock(#{LOCK_KEY})")
      begin
        refresh_due
      ensure
        conn.execute("SELECT pg_advisory_unlock(#{LOCK_KEY})")
      end
    end

    # Viewing an asset must never show a stale price just because the background worker is slow or absent.
    # Refreshes this one asset inline when its quote is older than `max_age` seconds; provider failures are swallowed
    # (the caller then shows whatever quote it has, flagged stale, and trading stays disabled).
    def self.refresh_one(asset, max_age: 60)
      q = asset.quote
      return q if q && Time.current - q.fetched_at < max_age
      return q if !asset.crypto? && !MarketCalendar.open? && q # equities don't move while the market is closed
      fetched = MarketData.quotes([ asset ])[asset.id] or return q
      rec = q || Quote.new(asset: asset)
      rec.update!(price: fetched.price, previous_close: fetched.previous_close, change_percent: fetched.change_percent,
                  as_of: fetched.as_of, fetched_at: Time.current, stats: fetched.stats)
      asset.association(:quote).reset
      rec
    rescue MarketData::ProviderError, ActiveRecord::RecordInvalid => e
      Rails.logger.warn("on-demand quote refresh failed for #{asset.symbol}: #{e.message}")
      q
    end

    def self.touch_view(asset) = Rails.cache.write("asset_view:#{asset.id}", Time.current.to_i, expires_in: VIEW_WINDOW)

    private

    def refresh_due
      market_open = MarketCalendar.open?
      priority_ids = priority_asset_ids
      quotes = Quote.where(asset_id: Asset.active.select(:id)).index_by(&:asset_id)
      due = Asset.active.select do |a|
        q = quotes[a.id]
        next true if @force || q.nil?
        age = Time.current - q.fetched_at
        if a.crypto? then age >= 55
        elsif market_open && priority_ids.include?(a.id) then age >= 55
        else age >= 15.minutes.to_i - 5
        end
      end
      return 0 if due.empty?

      fetched = MarketData.quotes(due)
      now = Time.current
      due.each do |asset|
        q = fetched[asset.id] or next
        rec = quotes[asset.id] || Quote.new(asset: asset)
        rec.update!(price: q.price, previous_close: q.previous_close, change_percent: q.change_percent,
                    as_of: q.as_of, fetched_at: now, stats: q.stats)
      rescue MarketData::ProviderError => e
        Rails.logger.warn("quote refresh failed for #{asset.symbol}: #{e.message}")
      end
      due.size
    end

    def priority_asset_ids
      ids = Position.distinct.pluck(:asset_id) | WatchlistItem.distinct.pluck(:asset_id)
      keys = Asset.active.pluck(:id).to_h { |id| [ "asset_view:#{id}", id ] }
      viewed = Rails.cache.read_multi(*keys.keys).keys.map { |k| keys[k] }
      ids | viewed
    end
  end
end
