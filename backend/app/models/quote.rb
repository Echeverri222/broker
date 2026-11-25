class Quote < ApplicationRecord
  belongs_to :asset
  FRESH_FOR = 60.seconds

  def fresh?(now = Clock.now) = fetched_at > now - FRESH_FOR
  def day_change = previous_close ? price - previous_close : BigDecimal("0")
end
