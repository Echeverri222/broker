class WarmMarketDataJob < ApplicationJob
  queue_as :default

  def perform = MarketData::Warm.call
end
