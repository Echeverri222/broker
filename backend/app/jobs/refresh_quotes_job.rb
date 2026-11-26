class RefreshQuotesJob < ApplicationJob
  queue_as :default

  def perform = Quotes::Refresh.call
end
