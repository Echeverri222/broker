module Api
  module V1
    class PortfolioController < ApplicationController
      before_action :authenticate!

      def show
        render json: Presenters.portfolio(current_account, Portfolios::Valuate.call(current_account))
      end

      def history
        range = params[:range].to_s.upcase.presence || "1M"
        render json: Portfolios::History.call(current_account, range: range,
                                              benchmark: params[:benchmark].to_s.upcase == "SPY")
      end
    end
  end
end
