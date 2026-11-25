module Snapshots
  # hourly: only accounts holding something whose market is open (crypto: always).
  # close:  everyone, once per US market close.
  class RecordAll
    def self.call(kind:)
      now = Clock.now
      market_open = MarketCalendar.open?(now)
      return if kind == :close && !MarketCalendar.trading_day?(now.in_time_zone(MarketCalendar::ZONE).to_date)
      close_at = MarketCalendar.close_at(now.in_time_zone(MarketCalendar::ZONE).to_date)
      Account.includes(positions: :asset).find_each do |account|
        next if kind == :hourly && !relevant?(account, market_open)
        # PERF-05: at most one close snapshot per account per day.
        next if kind == :close && PortfolioSnapshot.where(account: account).where("taken_at >= ?", close_at).exists?
        Record.call(account, at: now)
      end
    end

    # JOB-03: same eligibility rules, but one job per account. Returns the number of jobs enqueued.
    def self.enqueue(kind:)
      now = Clock.now
      market_open = MarketCalendar.open?(now)
      return 0 if kind == :close && !MarketCalendar.trading_day?(now.in_time_zone(MarketCalendar::ZONE).to_date)
      count = 0
      Account.includes(positions: :asset).find_in_batches(batch_size: 200) do |batch|
        batch.each do |account|
          next if kind == :hourly && !relevant?(account, market_open)
          SnapshotAccountJob.perform_later(account.id, now.utc.iso8601(6), kind.to_s)
          count += 1
        end
      end
      count
    end

    def self.relevant?(account, market_open)
      account.positions.any? { |p| p.asset.crypto? || market_open }
    end
  end
end
