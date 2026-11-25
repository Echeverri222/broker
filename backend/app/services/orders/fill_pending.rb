module Orders
  # QUE-06: fills waiting orders once the market is open, oldest first. Safe to run often and concurrently (row lock + status check).
  class FillPending
    def self.call(account: nil)
      return 0 unless MarketCalendar.open?
      scope = Order.pending.includes(:account, :asset).order(:id)
      scope = scope.where(account_id: account.id) if account
      scope.to_a.count do |order|
        Place.fill_pending(order).status != "pending"
      rescue ApiError, MarketData::ProviderError => e
        Rails.logger.info("waiting order #{order.id} not filled yet: #{e.message}")
        false
      end
    end
  end
end
