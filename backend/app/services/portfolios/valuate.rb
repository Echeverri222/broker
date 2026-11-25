module Portfolios
  # PRD PERF-01 / MKT-04. Portfolio value = cash + sum(quantity * latest price).
  # A held asset with no quote is NOT valued at a made-up price: it is excluded from the
  # total and the result is flagged incomplete.
  class Valuate
    Result = Struct.new(:cash, :invested_value, :total_value, :day_change, :rows, :incomplete, keyword_init: true)
    Row = Struct.new(:position, :asset, :quote, :price, :market_value, :unrealized_pnl, :day_change, :day_base, keyword_init: true) do
      def price_status = price ? "ok" : "missing"
      def day_percent = day_base&.positive? ? day_change / day_base * 100 : BigDecimal("0")
    end

    def self.call(account) = new(account).call

    def initialize(account) = @account = account

    def call
      positions = @account.positions.includes(asset: :quote).order(:id)
      today = trades_today
      rows = positions.map do |pos|
        quote = pos.asset.quote
        price = quote&.price
        change, base = day_pnl(quote, pos.quantity, today[pos.asset_id] || [])
        Row.new(position: pos, asset: pos.asset, quote: quote, price: price,
                market_value: price && pos.quantity * price,
                unrealized_pnl: price && (price - pos.average_cost) * pos.quantity,
                day_change: change || BigDecimal("0"), day_base: base)
      end
      priced = rows.select(&:price)
      invested = priced.sum(BigDecimal("0")) { |r| r.market_value }
      held_ids = positions.map(&:asset_id)
      # Assets bought and fully sold today still belong in "Today".
      closed_out = (today.keys - held_ids).sum(BigDecimal("0")) do |aid|
        trades = today[aid]
        change, = day_pnl(trades.first.asset.quote, BigDecimal("0"), trades)
        change || 0
      end
      day_change = priced.sum(BigDecimal("0")) { |r| r.day_change } + closed_out
      Result.new(cash: @account.cash, invested_value: invested, total_value: @account.cash + invested,
                 day_change: day_change, rows: rows, incomplete: priced.size != rows.size)
    end

    private

    # Filled orders since each asset's "today" began, grouped by asset.
    def trades_today
      now = Clock.now
      earliest = [ MarketCalendar.day_change_boundary(now), now - 24.hours ].min
      @account.orders.where(status: "filled").where("filled_at >= ?", earliest).includes(asset: :quote).to_a
              .select { |o| o.filled_at >= (o.asset.crypto? ? now - 24.hours : MarketCalendar.day_change_boundary(now)) }
              .group_by(&:asset_id)
    end

    # Today's gain for one asset = value now - value at the start of the day - cash put in by today's trades,
    # so a position bought this afternoon only counts moves since the purchase (not the move before it).
    # Returns [gain, base] or nil without a previous close.
    def day_pnl(quote, held_now, trades)
      return nil unless quote&.price && quote.previous_close
      bought = trades.select { |o| o.side == "buy" }
      sold = trades.select { |o| o.side == "sell" }
      start_units = held_now - bought.sum(BigDecimal("0"), &:quantity) + sold.sum(BigDecimal("0"), &:quantity)
      net_in = bought.sum(BigDecimal("0"), &:total) - sold.sum(BigDecimal("0"), &:total)
      gain = held_now * quote.price - start_units * quote.previous_close - net_in
      [ gain, start_units * quote.previous_close + bought.sum(BigDecimal("0"), &:total) ]
    end
  end
end
