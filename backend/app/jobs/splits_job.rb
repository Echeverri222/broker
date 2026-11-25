class SplitsJob < ApplicationJob
  def perform = CorporateActions::Sync.call
end
