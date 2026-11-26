module Api
  module V1
    # OBS-07: public, cheap, no user data. Explains "trading paused" and "delayed" to people who are not signed in.
    class StatusController < ApplicationController
      def show
        providers = MarketData::Gateway::DEFAULT_BUDGETS.keys.index_with { |p| MarketData::Gateway.state(p) }
        newest = Quote.maximum(:fetched_at)
        render json: { trading_enabled: Setting.trading_enabled?,
                       market_open: MarketCalendar.open?,
                       providers: providers,
                       quotes_updated_seconds_ago: newest && (Clock.now - newest).round,
                       degraded: !Setting.trading_enabled? || providers.values.any? { |s| s == "open" } }
      end
    end
  end
end
