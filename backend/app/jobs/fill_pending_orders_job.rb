# JOB-02: finds accounts with waiting orders and fans out one job per account, so 500 queued orders at the open are
# settled in parallel by the critical workers, each under its own account lock.
class FillPendingOrdersJob < ApplicationJob
  queue_as :critical

  def perform
    return 0 unless MarketCalendar.open?
    ids = Order.pending.distinct.pluck(:account_id)
    ids.each { |id| FillAccountOrdersJob.perform_later(id) }
    ids.size
  end
end
