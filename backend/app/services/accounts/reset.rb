module Accounts
  # RST-02: atomic. Watchlist and user stay.
  class Reset
    def self.call(account, confirm:)
      raise ApiError.new(:validation_failed, 'Type "RESET" to confirm.') unless confirm == "RESET"
      Account.transaction do
        account.lock!
        PortfolioSnapshot.where(account_id: account.id).delete_all
        Order.where(account_id: account.id).delete_all
        Position.where(account_id: account.id).delete_all
        Deposit.where(account_id: account.id).delete_all
        account.update!(cash: 0, reset_at: Clock.now)
        Provision.call(account)
      end
    end
  end
end
