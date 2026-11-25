module Api
  module V1
    class OrdersController < ApplicationController
      before_action :authenticate!
      rate_limit to: 60, within: 1.minute, only: %i[create destroy], by: -> { limit_key }, name: "orders", with: -> { rate_limited!(60) } # SEC-02
      PER_PAGE = 25
      MAX_LIMIT = 200

      def index
        page = Integer(params[:page].presence || 1, exception: false)
        raise ApiError.new(:validation_failed, "page must be a positive integer") unless page && page >= 1
        if params[:side].present? && !%w[buy sell].include?(params[:side])
          raise ApiError.new(:validation_failed, "side must be buy or sell")
        end
        # DAT-07: the asset page asks for `status=filled&limit=200` to draw the user's trades on the chart.
        if params[:status].present? && !Order::STATUSES.include?(params[:status])
          raise ApiError.new(:validation_failed, "status must be one of #{Order::STATUSES.join(', ')}")
        end
        per_page = Integer(params[:limit].presence || PER_PAGE, exception: false)
        raise ApiError.new(:validation_failed, "limit must be between 1 and #{MAX_LIMIT}") unless per_page && per_page.between?(1, MAX_LIMIT)
        scope = current_account.orders.includes(:asset).order(Arel.sql("COALESCE(filled_at, created_at) DESC"), id: :desc)
        scope = scope.where(side: params[:side]) if params[:side].present?
        scope = scope.where(status: params[:status]) if params[:status].present?
        if params[:symbol].present?
          asset = Asset.find_by(symbol: params[:symbol].to_s.upcase) or raise ApiError.new(:validation_failed, "Unknown symbol")
          scope = scope.where(asset: asset)
        end
        total = scope.count
        render json: { orders: scope.offset((page - 1) * per_page).limit(per_page).map { |o| Presenters.order(o) },
                       page: page, per_page: per_page, total: total }
      end

      def create
        result = Orders::Place.call(account: current_account, symbol: params.require(:symbol), side: params.require(:side),
                                    quantity: params[:quantity], amount: params[:amount], sell_all: params[:sell_all],
                                    idempotency_key: request.headers["Idempotency-Key"])
        account = current_account.reload
        pos = account.positions.includes(:asset).find_by(asset_id: result.order.asset_id)
        render json: { order: Presenters.order(result.order), cash: Fmt.money(account.cash),
                       reserved_cash: Fmt.money(account.reserved_cash), position: Presenters.position(pos) },
               status: result.created ? :created : :ok
      end

      def destroy
        order = Orders::Cancel.call(account: current_account, id: params[:id])
        render json: { order: Presenters.order(order), cash: Fmt.money(current_account.reload.cash),
                       reserved_cash: Fmt.money(current_account.reserved_cash) }
      end
    end
  end
end
