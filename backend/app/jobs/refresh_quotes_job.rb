class RefreshQuotesJob < ApplicationJob
  def perform = Quotes::Refresh.call
end
