class FillAccountOrdersJob < ApplicationJob
  queue_as :critical

  def perform(account_id)
    account = Account.find_by(id: account_id) or return
    Orders::FillPending.call(account: account)
  end
end
