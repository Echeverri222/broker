module Presenters
  module_function

  def quote(q)
    return nil unless q
    { price: Fmt.price(q.price), previous_close: Fmt.price(q.previous_close), change: Fmt.price(q.day_change),
      change_percent: Fmt.dec(q.change_percent, 2), as_of: Fmt.iso(q.as_of), fetched_at: Fmt.iso(q.fetched_at),
      stale: q.as_of < Clock.now - 2.minutes }
  end

  def asset(a, extra = {})
    { symbol: a.symbol, name: a.name, kind: a.kind, sector: a.sector, logo_url: a.logo_url, quote: quote(a.quote) }.merge(extra)
  end

  # DAT-03. Prices at 8 places, volumes as integer strings, percentages at 2 places; any value may be null.
  def stats(asset)
    s = MarketData::Stats.for(asset)
    out = s.slice("open", "day_low", "day_high", "week52_low", "week52_high").transform_values { |v| Fmt.price(v) }
    out.merge("volume" => Fmt.dec(s["volume"], 0), "avg_volume" => Fmt.dec(s["avg_volume"], 0),
              "change_1m_percent" => Fmt.dec(s["change_1m_percent"], 2), "change_1y_percent" => Fmt.dec(s["change_1y_percent"], 2)).symbolize_keys
  end

  # DAT-05: the extra per-row fields of the Markets list. Cache only, no provider calls.
  def list_asset(a, extra = {})
    s = MarketData::Stats.new(a)
    asset(a, extra).merge(change_percent: a.quote && Fmt.dec(a.quote.change_percent, 2), week52_position: Fmt.dec(s.week52_position, 4),
                          spark: s.spark, volume: Fmt.dec(s.volume, 0))
  end

  def order(o)
    { id: o.id, symbol: o.asset.symbol, name: o.asset.name, kind: o.asset.kind, side: o.side,
      quantity: o.quantity && Fmt.qty(o.quantity), price: o.price && Fmt.price(o.price), total: o.total && Fmt.money(o.total),
      realized_pnl: o.realized_pnl && Fmt.money(o.realized_pnl), status: o.status, filled_at: o.filled_at && Fmt.iso(o.filled_at),
      created_at: Fmt.iso(o.created_at), amount: o.amount && Fmt.money(o.amount),
      requested_quantity: o.requested_quantity && Fmt.qty(o.requested_quantity), sell_all: o.sell_all,
      reserved_cash: Fmt.money(o.reserved_cash), reject_reason: o.reject_reason }
  end

  def position(pos)
    return nil unless pos
    { symbol: pos.asset.symbol, quantity: Fmt.qty(pos.quantity), average_cost: Fmt.price(pos.average_cost) }
  end

  def deposit(d)
    { id: d.id, amount: Fmt.money(d.amount), kind: d.kind, created_at: Fmt.iso(d.created_at) }
  end

  def user(u)
    { id: u.id, name: u.name, email: u.email, verified: u.verified?, admin: u.admin, trading_enabled: Setting.trading_enabled?,
      preferences: { notify_order_filled: u.notify_order_filled, notify_order_rejected: u.notify_order_rejected },
      account: { cash: Fmt.money(u.account.cash), reserved_cash: Fmt.money(u.account.reserved_cash), net_deposits: Fmt.money(u.account.net_deposits) } }
  end

  def pct(change, base) = base.to_d.zero? ? BigDecimal("0") : (change / base * 100)

  def portfolio(account, v)
    start = account.net_deposits
    total_return = v.total_value - start
    prev_total = v.total_value - v.day_change
    {
      cash: Fmt.money(v.cash), reserved_cash: Fmt.money(account.reserved_cash), net_deposits: Fmt.money(start), total_value: Fmt.money(v.total_value), invested_value: Fmt.money(v.invested_value),
      day_change: Fmt.money(v.day_change), day_change_percent: Fmt.dec(pct(v.day_change, prev_total), 2),
      total_return: Fmt.money(total_return), total_return_percent: Fmt.dec(pct(total_return, start), 2),
      incomplete: v.incomplete,
      positions: v.rows.map do |r|
        p = r.position
        { symbol: r.asset.symbol, name: r.asset.name, kind: r.asset.kind, quantity: Fmt.qty(p.quantity),
          average_cost: Fmt.price(p.average_cost), price: Fmt.price(r.price), price_status: r.price_status,
          market_value: Fmt.money(r.market_value), unrealized_pnl: Fmt.money(r.unrealized_pnl),
          unrealized_pnl_percent: r.unrealized_pnl && Fmt.dec(pct(r.unrealized_pnl, p.quantity * p.average_cost), 2),
          day_change_percent: Fmt.dec(r.day_percent, 2), quote_as_of: Fmt.iso(r.quote&.as_of) }
      end
    }
  end
end
