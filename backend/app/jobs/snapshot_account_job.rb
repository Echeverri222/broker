class SnapshotAccountJob < ApplicationJob
  queue_as :default

  # `at` is fixed when the fan-out ran, so every account in one run shares one timestamp.
  def perform(account_id, at, kind = "hourly")
    account = Account.find_by(id: account_id) or return
    time = Time.iso8601(at)
    if kind == "close"
      close_at = MarketCalendar.close_at(time.in_time_zone(MarketCalendar::ZONE).to_date)
      return if PortfolioSnapshot.where(account: account).where("taken_at >= ?", close_at).exists? # PERF-05
    end
    Snapshots::Record.call(account, at: time)
  end
end
