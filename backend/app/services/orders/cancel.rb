module Orders
  # QUE-07: cancel a waiting order; repeating a cancel is a no-op, cancelling a settled order is a 409.
  class Cancel
    def self.call(account:, id:)
      Order.transaction do
        account.lock!
        order = account.orders.find_by(id: id) or raise ApiError.new(:not_found, "Order not found")
        case order.status
        when "cancelled" then order
        when "pending"
          order.update!(status: "cancelled", cancelled_at: Clock.now, reserved_cash: 0)
          order
        else raise ApiError.new(:order_not_pending, "This order has already #{order.status == 'filled' ? 'been filled' : 'been settled'} and can't be cancelled.")
        end
      end
    end
  end
end
