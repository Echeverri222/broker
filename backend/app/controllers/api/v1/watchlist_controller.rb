module Api
  module V1
    class WatchlistController < ApplicationController
      before_action :authenticate!

      def index
        items = current_user.watchlist_items.includes(asset: :quote).order(:created_at)
        render json: { assets: items.map { |i| Presenters.asset(i.asset) } }
      end

      def create
        asset = Asset.active.find_by!(symbol: params.require(:symbol).to_s.upcase)
        item = current_user.watchlist_items.find_or_create_by!(asset: asset)
        render json: Presenters.asset(asset.reload), status: item.previously_new_record? ? :created : :ok
      end

      def destroy
        asset = Asset.find_by!(symbol: params[:symbol].to_s.upcase)
        current_user.watchlist_items.where(asset: asset).destroy_all
        head :no_content
      end
    end
  end
end
