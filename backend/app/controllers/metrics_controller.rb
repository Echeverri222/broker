# OBS-03: Prometheus text format, scraped by the monitoring system. Protected by a bearer token (METRICS_TOKEN);
# without one configured the endpoint is off. Counts and ages only: no user data, no amounts.
class MetricsController < ActionController::API
  before_action :authorize!

  def show
    render plain: lines.join("\n") + "\n", content_type: "text/plain; version=0.0.4"
  end

  private

  def authorize!
    expected = ENV["METRICS_TOKEN"].to_s
    given = request.authorization.to_s.delete_prefix("Bearer ")
    ok = expected.present? && ActiveSupport::SecurityUtils.secure_compare(given, expected)
    head :not_found unless ok
  end

  def lines
    out = []
    metric = ->(name, value, labels = {}) do
      l = labels.empty? ? "" : "{#{labels.map { |k, v| %(#{k}="#{v}") }.join(',')}}"
      out << "#{name}#{l} #{value}"
    end
    QueueStats.depth_by_queue.each { |q, n| metric.("broker_queue_depth", n, queue: q) }
    metric.("broker_queue_oldest_ready_seconds", QueueStats.oldest_ready_age&.round || 0)
    metric.("broker_failed_jobs", QueueStats.failed(1000).size)
    MarketData::Gateway::DEFAULT_BUDGETS.each_key do |p|
      metric.("broker_provider_calls_this_minute", MarketData::Gateway.calls_this_minute(p), provider: p)
      metric.("broker_provider_circuit_open", MarketData::Gateway.open?(p) ? 1 : 0, provider: p)
    end
    held = Quote.where(asset_id: Position.select(:asset_id))
    metric.("broker_held_quote_age_seconds_max", held.minimum(:fetched_at) ? (Clock.now - held.minimum(:fetched_at)).round : 0)
    metric.("broker_orders_pending", Order.pending.count)
    metric.("broker_orders_total", Order.count, status: "all")
    metric.("broker_users_total", User.count)
    metric.("broker_calendar_days_remaining", MarketCalendar.days_remaining)
    metric.("broker_market_open", MarketCalendar.open? ? 1 : 0)
    metric.("broker_ledger_verify_problems", Setting.get("ledger_verify_problems", "0").to_i)
    metric.("broker_trading_enabled", Setting.trading_enabled? ? 1 : 0)
    pool = ActiveRecord::Base.connection_pool.stat
    metric.("broker_db_pool_busy", pool[:busy])
    metric.("broker_db_pool_size", pool[:size])
    out
  end
end
