module Api
  module V1
    class MarketController < ApplicationController
      # DAT-08: [label, symbol, proxy_for]. The indices are tracked with the funds that follow them.
      OVERVIEW = [ [ "S&P 500", "SPY", "SPY" ], [ "Nasdaq", "QQQ", "QQQ" ], [ "Bitcoin", "BTC", nil ] ].freeze

      def status
        cache_publicly(30)
        render json: MarketCalendar.status
      end

      # Cached quotes only (no provider call); items whose quote is missing are omitted.
      def overview
        cache_publicly(60)
        items = Rails.cache.fetch("market/overview/v1", expires_in: 60.seconds) do
          quotes = Quote.joins(:asset).where(assets: { symbol: OVERVIEW.map { |o| o[1] }, active: true }).includes(:asset).index_by { |q| q.asset.symbol }
          OVERVIEW.filter_map do |label, symbol, proxy|
            q = quotes[symbol] or next
            { symbol: symbol, label: label, price: Fmt.price(q.price), change_percent: Fmt.dec(q.change_percent, 2), proxy_for: proxy }
          end
        end
        render json: { items: items }
      end
    end
  end
end
