module Api
  module V1
    module Admin
      # ADM-03: enable or disable an asset and see how fresh its quote is. A disabled asset keeps its positions and
      # can still be sold, but cannot be bought (see Orders::Place).
      class AssetsController < BaseController
        def index
          q = params[:q].to_s.strip
          scope = Asset.includes(:quote).order(:symbol)
          scope = scope.where("symbol ILIKE :q OR name ILIKE :q", q: "%#{Asset.sanitize_sql_like(q)}%") if q.present?
          scope = scope.where(active: params[:active] == "true") if params[:active].present?
          render json: { assets: scope.limit(100).map { |a| present_asset(a) } }
        end

        def update
          asset = Asset.find_by!(symbol: params[:symbol].to_s.upcase)
          raise ApiError.new(:validation_failed, "active must be true or false") unless [ true, false ].include?(params[:active])
          asset.update!(active: params[:active])
          audit(:admin_asset_changed, symbol: asset.symbol, active: asset.active)
          render json: present_asset(asset)
        end

        private

        def present_asset(a)
          q = a.quote
          { symbol: a.symbol, name: a.name, kind: a.kind, active: a.active, held_by: Position.where(asset_id: a.id).count,
            quote_age_seconds: q && (Clock.now - q.fetched_at).round, last_price: q && Fmt.price(q.price),
            provider: a.kind == "crypto" ? "coingecko" : "yahoo" }
        end
      end
    end
  end
end
