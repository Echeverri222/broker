# SCL-08: keep every snapshot for 7 days, then one per hour until 90 days, then one per day. Nightly, `low` queue.
# Always kept, so PERF-04 results do not change: the first and last snapshot of each day, and the snapshots on either
# side of every deposit.
class CompactSnapshotsJob < ApplicationJob
  queue_as :low

  FULL_FOR = 7.days
  HOURLY_FOR = 90.days

  def perform(now = Clock.now)
    deleted = 0
    Account.find_each { |account| deleted += compact(account, now) }
    deleted
  end

  private

  def compact(account, now)
    cutoff = now - FULL_FOR
    snaps = account.portfolio_snapshots.where("taken_at < ?", cutoff).order(:taken_at, :id).pluck(:id, :taken_at)
    return 0 if snaps.size < 3
    keep = Set.new
    snaps.group_by { |_, t| t.utc.to_date }.each_value { |day| keep << day.first[0] << day.last[0] }
    snaps.group_by { |_, t| t < now - HOURLY_FOR ? t.utc.to_date : t.utc.beginning_of_hour }.each_value { |bucket| keep << bucket.last[0] }
    account.deposits.pluck(:created_at).each do |at|
      before = snaps.reverse.find { |_, t| t <= at }
      after = snaps.find { |_, t| t >= at }
      keep << before[0] if before
      keep << after[0] if after
    end
    drop = snaps.map(&:first) - keep.to_a
    drop.each_slice(1000) { |ids| PortfolioSnapshot.where(id: ids).delete_all }
    drop.size
  end
end
