# NTF-01/02: emails the owner when a waiting order settles, if they opted in. Only for orders that were queued.
class OrderNotificationJob < ApplicationJob
  queue_as :default

  def perform(order_id)
    order = Order.includes(account: :user).find_by(id: order_id) or return
    user = order.account.user
    return if user.deleted? || user.disabled?
    case order.status
    when "filled" then UserMailer.order_filled(order).deliver_now if user.notify_order_filled
    when "rejected" then UserMailer.order_rejected(order).deliver_now if user.notify_order_rejected
    end
  end
end
