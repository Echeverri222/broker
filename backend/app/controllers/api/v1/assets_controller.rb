module Api
  module V1
    class AssetsController < ApplicationController
      before_action :authenticate!
      rate_limit to: 120, within: 1.minute, only: %i[index candles], by: -> { limit_key }, name: "search", with: -> { rate_limited!(60) } # SEC-02

      FILTERS = %w[watching owned gainers losers most_traded near_high under_50 open].freeze
      SORTS = %w[change price_asc price_desc name volume change_1m].freeze
      MAX_LIMIT = 50
      DEFAULT_LIMIT = 25
      MOST_TRADED_TOP = 10

      Row = Struct.new(:asset, :stats) do
        def quote = asset.quote
        def price = quote&.price
        def change = quote&.change_percent
        def change_1m = stats.to_h["change_1m_percent"]
      end

      # MKT-06: provider failures on candles are a clean 503, never a 500.
      rescue_from MarketData::ProviderError do
        render_error(:price_unavailable, "Price history is temporarily unavailable. Please retry.")
      end

      # DAT-05. Reads the database and the warm cache only; never calls a provider.
      def index
        opts = list_options
        matched, fuzzy = matching(params[:q].to_s.strip)
        rows = matched.map { |a| Row.new(a, MarketData::Stats.new(a)) }
        watched = current_user.watchlist_items.pluck(:asset_id).to_set
        owned = current_account.positions.where("quantity > 0").pluck(:asset_id).to_set

        counts = { all: rows.size, stock: rows.count { |r| r.asset.kind == "stock" }, etf: rows.count { |r| r.asset.kind == "etf" },
                   crypto: rows.count { |r| r.asset.kind == "crypto" },
                   watching: rows.count { |r| watched.include?(r.asset.id) }, owned: rows.count { |r| owned.include?(r.asset.id) } }

        top_volume = rows.select { |r| r.stats.volume }.max_by(MOST_TRADED_TOP) { |r| r.stats.volume }.to_set
        list = rows
        list = list.select { |r| r.asset.kind == opts[:kind] } if opts[:kind]
        list = list.select { |r| r.asset.sector == opts[:sector] } if opts[:sector]
        opts[:filters].each { |f| list = list.select { |r| passes?(f, r, watched: watched, owned: owned, top_volume: top_volume) } }
        list = sort_rows(list, opts[:sort])

        page_rows = list.slice((opts[:page] - 1) * opts[:limit], opts[:limit]) || []
        render json: { assets: page_rows.map { |r| Presenters.list_asset(r.asset, watched: watched.include?(r.asset.id)) },
                       meta: { total: list.size, page: opts[:page], limit: opts[:limit], counts: counts, fuzzy: fuzzy,
                               sectors: Asset.active.where.not(sector: nil).distinct.order(:sector).pluck(:sector) } }
      end

      def show
        asset = Asset.active.includes(:quote).find_by!(symbol: params[:symbol].upcase)
        Quotes::Refresh.touch_view(asset)
        Quotes::Refresh.request_refresh(asset)
        pos = current_account.positions.find_by(asset: asset)
        render json: Presenters.asset(asset,
          watched: current_user.watchlist_items.exists?(asset: asset),
          stats: Presenters.stats(asset),
          position: pos && { quantity: Fmt.qty(pos.quantity), average_cost: Fmt.price(pos.average_cost),
                             market_value: asset.quote && Fmt.money(pos.quantity * asset.quote.price) })
      end

      def candles
        asset = Asset.active.find_by!(symbol: params[:symbol].upcase)
        range = params[:range].to_s.upcase
        raise ApiError.new(:validation_failed, "range must be one of #{MarketData::RANGES.join(', ')}") unless MarketData::RANGES.include?(range)
        interval = begin
          MarketData.interval_for(range, params[:interval].to_s.downcase)
        rescue ArgumentError => e
          raise ApiError.new(:validation_failed, e.message)
        end
        data = MarketData.candles(asset, range: range, interval: interval)
        render json: { symbol: asset.symbol, range: range, interval: interval,
                       candles: data.map { |c| { time: c.time, open: Fmt.price(c.open), high: Fmt.price(c.high), low: Fmt.price(c.low), close: Fmt.price(c.close),
                                                 volume: c.volume&.to_s } } }
      end

      private

      def list_options
        kind = params[:kind].presence
        raise ApiError.new(:validation_failed, "kind must be one of #{Asset::KINDS.join(', ')}") if kind && !Asset::KINDS.include?(kind)
        filters = params[:filter].to_s.split(",").map(&:strip).reject(&:empty?).uniq
        bad = filters - FILTERS
        raise ApiError.new(:validation_failed, "filter must be a comma list of #{FILTERS.join(', ')}") if bad.any?
        sort = params[:sort].presence || "change"
        raise ApiError.new(:validation_failed, "sort must be one of #{SORTS.join(', ')}") unless SORTS.include?(sort)
        sector = params[:sector].presence
        raise ApiError.new(:validation_failed, "Unknown sector") if sector && !Asset.active.exists?(sector: sector)
        { kind: kind, filters: filters, sort: sort, sector: sector,
          page: positive_int(:page, 1), limit: positive_int(:limit, DEFAULT_LIMIT, max: MAX_LIMIT) }
      end

      def positive_int(name, default, max: nil)
        return default if params[name].blank?
        v = Integer(params[name].to_s, exception: false)
        raise ApiError.new(:validation_failed, "#{name} must be a positive integer#{" up to #{max}" if max}") unless v && v >= 1 && (max.nil? || v <= max)
        v
      end

      # Search (substring first, typo-tolerant fallback when nothing matches). Returns [assets, fuzzy?].
      def matching(q)
        base = Asset.active.includes(:quote)
        return [ base.to_a, false ] if q.empty?
        found = base.search(q)
        return [ found.to_a, false ] if found.exists?
        [ base.fuzzy(q).to_a, true ]
      end

      def passes?(filter, row, watched:, owned:, top_volume:)
        case filter
        when "watching" then watched.include?(row.asset.id)
        when "owned" then owned.include?(row.asset.id)
        when "gainers" then row.change.to_d.positive?
        when "losers" then row.change.to_d.negative?
        when "most_traded" then top_volume.include?(row)
        when "near_high" then (row.stats.week52_position || 0) >= 0.95
        when "under_50" then !row.price.nil? && row.price < 50
        when "open" then row.asset.crypto? || MarketCalendar.open?
        end
      end

      # Rows missing the sort value always go last.
      def sort_rows(rows, sort)
        key = case sort
        when "change" then ->(r) { r.change&.abs }
        when "price_asc" then ->(r) { r.price }
        when "price_desc" then ->(r) { r.price && -r.price }
        when "name" then ->(r) { r.asset.name.downcase }
        when "volume" then ->(r) { r.stats.volume && -r.stats.volume }
        when "change_1m" then ->(r) { r.change_1m&.abs }
        end
        desc = %w[change change_1m].include?(sort)
        present, missing = rows.partition { |r| key.call(r) }
        present = present.sort_by { |r| [ key.call(r), r.asset.symbol ] }
        present = present.sort_by { |r| [ -key.call(r), r.asset.symbol ] } if desc
        present + missing.sort_by { |r| r.asset.symbol }
      end
    end
  end
end
