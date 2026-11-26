# Runtime switches that must change without a deploy (ADM-05).
class Setting < ApplicationRecord
  validates :key, presence: true, uniqueness: true

  def self.get(key, default = nil) = find_by(key: key)&.value || default
  def self.set(key, value) = find_or_initialize_by(key: key).tap { |s| s.update!(value: value.to_s) }

  def self.trading_enabled? = get("trading_enabled", "true") == "true"
end
