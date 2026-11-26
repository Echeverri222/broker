# NYSE regular session 09:30:00 (inclusive) - 16:00:00 (exclusive) ET, Mon-Fri.
# Holidays and early closes (13:00 ET) come from the tables below.
# Fail safe (CAL-04): past the end of the table the market counts as closed.
module MarketCalendar
  ZONE = ActiveSupport::TimeZone["America/New_York"]
  OPEN_AT = [ 9, 30 ].freeze
  CLOSE_AT = [ 16, 0 ].freeze
  EARLY_CLOSE_AT = [ 13, 0 ].freeze

  HOLIDAYS = %w[
    2026-01-01 2026-01-19 2026-02-16 2026-04-03 2026-05-25 2026-06-19 2026-07-03 2026-09-07 2026-11-26 2026-12-25
    2027-01-01 2027-01-18 2027-02-15 2027-03-26 2027-05-31 2027-06-18 2027-07-05 2027-09-06 2027-11-25 2027-12-24
    2028-01-17 2028-02-21 2028-04-14 2028-05-29 2028-06-19 2028-07-04 2028-09-04 2028-11-23 2028-12-25
  ].map { |d| Date.parse(d) }.freeze

  EARLY_CLOSES = %w[
    2026-11-27 2026-12-24
    2027-11-26
    2028-07-03 2028-11-24
  ].map { |d| Date.parse(d) }.freeze

  # Last date for which the tables are known to be complete.
  COVERED_THROUGH = Date.new(2028, 12, 31)

  # CAL-07: warn when fewer than this many days of calendar remain, long before stocks silently stop trading.
  WARN_DAYS = 90

  module_function

  def covered?(date) = date <= COVERED_THROUGH

  def days_remaining(today = Clock.now.in_time_zone(ZONE).to_date) = (COVERED_THROUGH - today).to_i

  def trading_day?(date) = covered?(date) && !date.saturday? && !date.sunday? && !HOLIDAYS.include?(date)
  def early_close?(date) = EARLY_CLOSES.include?(date)

  def open_at(date) = ZONE.local(date.year, date.month, date.day, *OPEN_AT)

  def close_at(date)
    ZONE.local(date.year, date.month, date.day, *(early_close?(date) ? EARLY_CLOSE_AT : CLOSE_AT))
  end

  def status(now = Clock.now)
    now = now.in_time_zone(ZONE)
    today = now.to_date
    Rails.logger.error("MarketCalendar: #{today} is past the end of the table; treating market as closed") unless covered?(today)
    is_open = trading_day?(today) && now >= open_at(today) && now < close_at(today)
    next_open = is_open ? next_session_open(today + 1) : next_open_after(now)
    next_close = is_open ? close_at(today) : (next_open && close_at(next_open.to_date))
    {
      open: is_open,
      next_open: next_open&.utc&.iso8601,
      next_close: next_close&.utc&.iso8601,
      session: is_open ? "regular" : "closed",
      early_close: is_open ? early_close?(today) : (next_open ? early_close?(next_open.to_date) : false)
    }
  end

  def open?(now = Clock.now) = status(now)[:open]

  # Start of "today" for day-change maths: the close before the most recent session (what quotes call previous close).
  # Falls back to 24h ago outside the calendar.
  def day_change_boundary(now = Clock.now)
    t = now.in_time_zone(ZONE)
    day = t.to_date
    10.times { break if trading_day?(day) && open_at(day) <= t; day -= 1 }
    return now - 24.hours unless trading_day?(day) && open_at(day) <= t
    prev = day - 1
    10.times { break if trading_day?(prev); prev -= 1 }
    trading_day?(prev) ? close_at(prev).utc : now - 24.hours
  end

  def next_open_after(now)
    today = now.to_date
    return open_at(today) if trading_day?(today) && now < open_at(today)
    next_session_open(today + 1)
  end

  def next_session_open(date)
    date += 1 until trading_day?(date) || !covered?(date)
    covered?(date) ? open_at(date) : nil
  end

  def next_trading_day_from(date) = next_session_open(date)&.to_date
end
