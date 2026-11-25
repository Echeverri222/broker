# SES-03: keeps the sessions table small. Expired and long-idle sessions are removed.
class PruneSessionsJob < ApplicationJob
  queue_as :low

  def perform = Session.expired.in_batches(of: 1000).delete_all
end
