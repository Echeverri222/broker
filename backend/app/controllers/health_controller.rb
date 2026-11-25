# OBS-06. `/up` (Rails' own) is liveness. `/up/deep` is readiness for monitors: it checks what users depend on and
# answers 503 with a list of reasons. Load balancers should keep using `/up`.
class HealthController < ActionController::API
  QUOTE_MAX_AGE = 5.minutes
  QUEUE_MAX_LAG = 2.minutes

  def deep
    problems = checks
    render json: { status: problems.empty? ? "ok" : "degraded", problems: problems, checked_at: Fmt.iso(Clock.now) },
           status: problems.empty? ? :ok : :service_unavailable
  end

  private

  def checks
    problems = []
    begin
      ActiveRecord::Base.connection.select_value("SELECT 1")
    rescue StandardError
      return [ "database unreachable" ]
    end
    problems << "trading paused" unless Setting.trading_enabled?
    newest = Quote.maximum(:fetched_at)
    if newest.nil? || newest < Clock.now - QUOTE_MAX_AGE
      problems << "quotes stale (last refresh #{newest ? "#{((Clock.now - newest) / 60).round} min ago" : 'never'})" if MarketCalendar.open? || newest.nil?
    end
    days = MarketCalendar.days_remaining
    problems << "market calendar ends in #{days} days" if days < MarketCalendar::WARN_DAYS # CAL-07
    lag = QueueStats.oldest_ready_age
    problems << "job queue lagging #{lag.round}s" if lag && lag > QUEUE_MAX_LAG
    MarketData::Gateway::DEFAULT_BUDGETS.each_key do |p|
      problems << "#{p} circuit open" if MarketData::Gateway.open?(p)
    end
    problems
  end
end
