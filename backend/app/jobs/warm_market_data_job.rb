class WarmMarketDataJob < ApplicationJob
  queue_as :low

  def perform = MarketData::Warm.call
end
