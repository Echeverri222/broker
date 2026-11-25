module Snapshots
  class Record
    def self.call(account, at: Clock.now)
      v = Portfolios::Valuate.call(account)
      PortfolioSnapshot.create!(account: account, total_value: v.total_value.round(2), cash: v.cash,
                                invested_value: v.invested_value.round(2), net_deposits: account.net_deposits, taken_at: at)
    end
  end
end
