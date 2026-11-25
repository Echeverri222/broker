module Api
  module V1
    module Admin
      # ADM-05: the trading kill switch. Takes effect immediately for new orders and fills; no deploy needed.
      class SettingsController < BaseController
        def show = render(json: payload)

        def update
          unless [ true, false, "true", "false" ].include?(params[:trading_enabled])
            raise ApiError.new(:validation_failed, "trading_enabled must be true or false")
          end
          enabled = params[:trading_enabled].to_s == "true"
          Setting.set("trading_enabled", enabled)
          audit(:admin_trading_changed, trading_enabled: enabled)
          render json: payload
        end

        private

        def payload = { trading_enabled: Setting.trading_enabled? }
      end
    end
  end
end
