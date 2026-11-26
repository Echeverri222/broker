class SplitsJob < ApplicationJob
  queue_as :default

  def perform = CorporateActions::Sync.call
end
