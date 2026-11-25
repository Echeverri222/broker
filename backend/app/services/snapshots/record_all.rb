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

    def self.relevant?(account, market_open)
      account.positions.any? { |p| p.asset.crypto? || market_open }
    end
  end
end
