class FillPendingOrdersJob < ApplicationJob
  queue_as :default

  def perform = Orders::FillPending.call
end
