module MarketData
  # MKD-07: concurrent cache misses for the same key wait for one fetch instead of each calling the provider.
  # Uses a Postgres advisory lock so it also works across processes. The block runs at most once per miss.
  module SingleFlight
    module_function

    def fetch(key, expires_in:)
      cached = Rails.cache.read(key)
      return cached unless cached.nil?
      ActiveRecord::Base.with_connection do |conn|
        conn.execute("SELECT pg_advisory_lock(hashtextextended(#{conn.quote(key)}, 0))")
        begin
          cached = Rails.cache.read(key)
          return cached unless cached.nil?
          value = yield
          Rails.cache.write(key, value, expires_in: expires_in)
          value
        ensure
          conn.execute("SELECT pg_advisory_unlock(hashtextextended(#{conn.quote(key)}, 0))")
        end
      end
    end
  end
end
