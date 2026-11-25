module Orders
  # Market order, filled instantly and fully at the stored real quote.
  # See PRD v2 §5 (ORD rules) and MON-04 for the exact rounding formulas.
  class Place
    MIN_ORDER = BigDecimal("1")
    MAX_PENDING = 20
    DAILY_ORDER_LIMIT = 500 # SEC-04: orders created per account per rolling 24 hours
    RESERVE_BUFFER = BigDecimal("1.05") # QUE-04: quantity-sized queued buys reserve 5% extra for a gap at the open
    STOCK_MAX_AGE = 15.minutes
    CRYPTO_MAX_AGE = 5.minutes

    Result = Struct.new(:order, :created, keyword_init: true)

    def self.call(**kw) = new(**kw).call

    def initialize(account:, symbol:, side:, quantity: nil, amount: nil, sell_all: nil, idempotency_key: nil, pending: nil)
      @account = account
      @pending = pending
      @symbol = symbol.to_s.strip.upcase
      @side = side.to_s
      @raw_sell_all = sell_all
      @quantity = DecimalInput.parse(quantity, "quantity", max_places: 8)
      @amount = DecimalInput.parse(amount, "amount", max_places: 2)
      @key = idempotency_key.to_s
      @sell_all = [ true, "true" ].include?(sell_all)
    end

    def call
      raise_if_paused!
      validate_input!
      asset = Asset.active.find_by(symbol: @symbol) or raise ApiError.new(:not_found, "Unknown asset #{@symbol}")

      if (existing = @account.orders.find_by(idempotency_key: @key))
        return replay(existing)
      end
      if @account.orders.where("created_at > ?", Clock.now - 24.hours).count >= DAILY_ORDER_LIMIT
        raise ApiError.new(:validation_failed, "Daily limit of #{DAILY_ORDER_LIMIT} orders reached. Try again tomorrow.")
      end

      now = Clock.now
      return enqueue(asset, now) if closed?(asset, now) # QUE-01: stocks placed while the market is closed wait for the open
      quote = usable_quote!(asset, now)

      Order.transaction do
        @account.lock!
        if (existing = @account.orders.find_by(idempotency_key: @key))
          return replay(existing)
        end
        return enqueue_locked(asset, now) if closed?(asset, now) # ORD-14: same `now`, inside the lock
        order = @side == "buy" ? buy(asset, quote.price, now) : sell(asset, quote.price, now)
        Result.new(order: order, created: true)
      end
    rescue ActiveRecord::RecordNotUnique
      replay(@account.orders.find_by!(idempotency_key: @key))
    end

    # QUE-06: called by the fill job / lazily on reads. Leaves the order pending when the market is closed or the price
    # is not usable yet (price_unavailable propagates); a business failure (funds, quantity, minimum) rejects it.
    def self.fill_pending(order)
      new(account: order.account, symbol: order.asset.symbol, side: order.side,
          quantity: order.requested_quantity&.to_s("F"), amount: (order.requested_quantity ? nil : order.amount&.to_s("F")),
          sell_all: order.sell_all || nil, idempotency_key: order.idempotency_key, pending: order).fill_pending!
    end

    def fill_pending!
      return @pending unless Setting.trading_enabled? # ADM-05: waiting orders stay waiting while trading is paused
      asset = @pending.asset
      now = Clock.now
      return @pending if closed?(asset, now)
      quote = usable_quote!(asset, now)
      settled = false
      Order.transaction do
        @account.lock!
        @pending.reload
        next unless @pending.status == "pending"
        begin
          @side == "buy" ? buy(asset, quote.price, now) : sell(asset, quote.price, now)
        rescue ApiError => e
          raise if e.code == :price_unavailable
          @pending.update!(status: "rejected", reject_reason: e.message, reserved_cash: 0)
        end
        settled = true
      end
      @pending.reload
      OrderNotificationJob.perform_later(@pending.id) if settled # NTF-01: only the call that settled it notifies
      @pending
    end

    private

    # ADM-05: the kill switch blocks new orders only; cancelling and reading keep working.
    def raise_if_paused!
      return if Setting.trading_enabled?
      raise ApiError.new(:trading_paused, "Trading is paused for maintenance. Your cash and positions are safe. Please try again soon.")
    end

    def enqueue(asset, now)
      Order.transaction do
        @account.lock!
        enqueue_locked(asset, now)
      end
    end

    def enqueue_locked(asset, now)
      if (existing = @account.orders.find_by(idempotency_key: @key))
        return replay(existing)
      end
      if @account.orders.pending.count >= MAX_PENDING
        raise ApiError.new(:too_many_pending_orders, "You can have at most #{MAX_PENDING} waiting orders. Cancel one first.")
      end
      order = @side == "buy" ? queue_buy(asset) : queue_sell(asset)
      Result.new(order: order, created: true)
    end

    def queue_buy(asset)
      price = asset.quote&.price
      if @amount
        total = reserve = @amount
      else
        raise unavailable(asset) unless price&.positive? # need a price to size the reservation
        total = (@quantity * price).round(2, :half_up)
        reserve = (total * RESERVE_BUFFER).ceil(2)
      end
      raise ApiError.new(:below_minimum, "Minimum order is $1.00") if total < MIN_ORDER
      avail = @account.available_cash
      if reserve > avail
        raise ApiError.new(:insufficient_funds, "Not enough cash. You have $#{Fmt.money(avail)} available to spend.", max_amount: Fmt.money([ avail, 0 ].max))
      end
      create_pending(asset, amount: @amount, requested_quantity: @quantity, reserved_cash: reserve)
    end

    def queue_sell(asset)
      held = @account.positions.find_by(asset: asset)&.quantity || BigDecimal("0")
      waiting = @account.orders.pending.where(asset: asset, side: "sell")
      if waiting.exists?
        raise ApiError.new(:insufficient_quantity, "You already have a waiting sell order for #{asset.symbol}. Cancel it to place another.",
                           max_quantity: Fmt.qty(0), max_amount: Fmt.money(0))
      end
      if @sell_all
        raise ApiError.new(:insufficient_quantity, "You don't hold any #{asset.symbol}.", max_quantity: Fmt.qty(0), max_amount: Fmt.money(0)) if held.zero?
        return create_pending(asset, sell_all: true)
      end
      price = asset.quote&.price
      raise unavailable(asset) unless price&.positive?
      qty = @amount ? (@amount / price).round(8, :down) : @quantity
      if qty > held
        raise ApiError.new(:insufficient_quantity, "You only hold #{Fmt.qty(held)} #{asset.symbol}.",
                           max_quantity: Fmt.qty(held), max_amount: Fmt.money((held * price).round(2, :half_up)))
      end
      raise ApiError.new(:below_minimum, "Minimum order is $1.00") if qty.zero? || (qty * price).round(2, :half_up) < MIN_ORDER
      create_pending(asset, amount: @amount, requested_quantity: qty)
    end

    def create_pending(asset, amount: nil, requested_quantity: nil, sell_all: false, reserved_cash: 0)
      @account.orders.create!(asset: asset, side: @side, status: "pending", amount: amount, requested_quantity: requested_quantity,
                              sell_all: sell_all, reserved_cash: reserved_cash, idempotency_key: @key, request_hash: request_hash)
    end

    # Cash that may be spent right now: everything except what other queued buys have reserved.
    def spendable
      @account.cash - @account.orders.pending.where.not(id: @pending&.id).sum(:reserved_cash)
    end

    def validate_input!
      unless @key.match?(/\A[\x20-\x7E]{1,255}\z/)
        raise ApiError.new(:idempotency_key_required, "An Idempotency-Key header (1-255 printable characters) is required.")
      end
      raise ApiError.new(:validation_failed, "side must be buy or sell") unless %w[buy sell].include?(@side)
      unless [ nil, true, false, "true", "false" ].include?(@raw_sell_all)
        raise ApiError.new(:validation_failed, "sell_all must be true")
      end
      @sell_all = false if [ false, "false" ].include?(@raw_sell_all)
      given = [ @quantity, @amount, (@sell_all || nil) ].compact.size
      raise ApiError.new(:validation_failed, "Provide exactly one of quantity, amount or sell_all") unless given == 1
      raise ApiError.new(:validation_failed, "sell_all is only valid for sell orders") if @sell_all && @side != "sell"
    end

    def request_hash
      payload = [ @symbol, @side, @quantity&.to_s("F"), @amount&.to_s("F"), @sell_all ].to_json
      Digest::SHA256.hexdigest(payload)
    end

    def replay(order)
      if order.request_hash.present? && order.request_hash != request_hash
        raise ApiError.new(:idempotency_conflict, "This Idempotency-Key was already used with a different order.")
      end
      Result.new(order: order, created: false)
    end

    # True when a stock must wait for the open. With no known next session (calendar exhausted) we refuse instead.
    def closed?(asset, now)
      return false if asset.crypto?
      status = MarketCalendar.status(now)
      return false if status[:open]
      unless status[:next_open]
        raise ApiError.new(:market_closed, "The US market is closed and no upcoming session is known.", next_open: nil)
      end
      true
    end

    # MKD-03 (ORD-10/11/12): orders use the STORED quote only. If it is older than FETCH_MAX_AGE (the refresh job is
    # behind or the provider is down) or its as_of is too old, the order fails with price_unavailable and ONE
    # background refresh is requested. A request never calls a provider.
    FETCH_MAX_AGE = 3.minutes

    def usable_quote!(asset, now)
      quote = asset.quote
      max_age = asset.crypto? ? CRYPTO_MAX_AGE : STOCK_MAX_AGE
      usable = quote&.price&.positive? && quote.as_of >= now - max_age && quote.fetched_at >= now - FETCH_MAX_AGE
      unless usable
        Quotes::Refresh.request_refresh(asset, max_age: 0)
        raise unavailable(asset)
      end
      Quotes::Refresh.request_refresh(asset) # keep it warm, deduplicated
      quote
    end

    def unavailable(asset)
      ApiError.new(:price_unavailable, "Price is temporarily unavailable for #{asset.symbol}. Try again shortly.")
    end

    def buy(asset, price, now)
      if @amount
        total = @amount
        qty = (@amount / price).round(8, :down)
      else
        qty = @quantity
        total = (qty * price).round(2, :half_up)
      end
      raise ApiError.new(:below_minimum, "Minimum order is $1.00") if qty.zero? || total < MIN_ORDER
      cash = spendable
      if total > cash
        raise ApiError.new(:insufficient_funds, "Not enough cash. You have $#{Fmt.money(cash)} available.",
                           max_amount: Fmt.money([ cash, 0 ].max))
      end

      pos = @account.positions.find_or_initialize_by(asset: asset)
      if pos.persisted?
        new_qty = pos.quantity + qty
        pos.average_cost = ((pos.quantity * pos.average_cost + qty * price) / new_qty).round(8, :half_up)
        pos.quantity = new_qty
      else
        pos.quantity = qty
        pos.average_cost = price.round(8, :half_up)
      end
      pos.save!
      @account.update!(cash: @account.cash - total)
      create_order(asset, qty, price, total, nil, now)
    end

    def sell(asset, price, now)
      pos = @account.positions.find_by(asset: asset)
      held = pos&.quantity || BigDecimal("0")
      if @sell_all
        raise ApiError.new(:insufficient_quantity, "You don't hold any #{asset.symbol}.", max_quantity: Fmt.qty(0), max_amount: Fmt.money(0)) if pos.nil?
        qty = held
        total = (qty * price).round(2, :half_up)
        raise ApiError.new(:below_minimum, "This position is worth less than one cent and cannot be sold.") if total <= 0
      else
        if @amount
          total = @amount
          qty = (@amount / price).round(8, :down)
        else
          qty = @quantity
          total = (qty * price).round(2, :half_up)
        end
        if qty > held
          raise ApiError.new(:insufficient_quantity, "You only hold #{Fmt.qty(held)} #{asset.symbol}.",
                             max_quantity: Fmt.qty(held), max_amount: Fmt.money((held * price).round(2, :half_up)))
        end
        raise ApiError.new(:below_minimum, "Minimum order is $1.00") if qty.zero? || total < MIN_ORDER
      end

      realized = ((price - pos.average_cost) * qty).round(2, :half_up)
      if qty == held then pos.destroy! else pos.update!(quantity: held - qty) end
      @account.update!(cash: @account.cash + total)
      create_order(asset, qty, price, total, realized, now)
    end

    def create_order(asset, qty, price, total, realized, now)
      attrs = { quantity: qty, price: price, total: total, realized_pnl: realized, status: "filled", filled_at: now, reserved_cash: 0 }
      order = if @pending
        @pending.update!(attrs)
        @pending
      else
        @account.orders.create!(attrs.merge(asset: asset, side: @side, idempotency_key: @key, request_hash: request_hash))
      end
      Snapshots::Record.call(@account, at: now)
      order
    end
  end
end
