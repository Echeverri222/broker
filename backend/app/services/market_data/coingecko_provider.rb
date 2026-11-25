module MarketData
  # CoinGecko public API (no key required; COINGECKO_API_KEY, a free demo key, is used if set).
  # `assets.provider_ref` holds the CoinGecko coin id.
  class CoingeckoProvider
    include Http
    URL = "https://api.coingecko.com/api/v3/simple/price".freeze

    def quotes(assets)
      return {} if assets.empty?
      ids = assets.map(&:provider_ref).join(",")
      headers = ENV["COINGECKO_API_KEY"].present? ? { "x-cg-demo-api-key" => ENV["COINGECKO_API_KEY"] } : {}
      body = get_json("#{URL}?ids=#{ids}&vs_currencies=usd&include_24hr_change=true&include_last_updated_at=true", headers)
      assets.each_with_object({}) do |a, out|
        row = body[a.provider_ref] or next
        # MKT-02: price and timestamp are mandatory; omit the coin (caller keeps its old quote) if absent.
        unless row.is_a?(Hash) && row["usd"].is_a?(Numeric) && row["usd"].positive? && row["last_updated_at"].is_a?(Integer)
          Rails.logger.warn("coingecko: incomplete data for #{a.symbol}")
          next
        end
        price = row["usd"].to_d
        pct = (row["usd_24h_change"] || 0).to_d
        prev = (price / (1 + pct / 100)).round(8)
        out[a.id] = MarketData::Quote.new(price: price, previous_close: prev, change: price - prev,
                                          change_percent: pct.round(4),
                                          as_of: Time.at(row["last_updated_at"]).utc)
      end
    end
  end
end
