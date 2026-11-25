# DR-02: hourly read-only check of MON-05/MON-06 in production. A mismatch is reported (error tracker / alert).
# Only account ids and rule ids are logged, never balances.
class LedgerVerifyJob < ApplicationJob
  queue_as :low

  def perform
    problems = Ledger::Verify.call
    problems.each { |p| Rails.logger.error("ledger mismatch account=#{p[:account_id]} rule=#{p[:rule]}") }
    Rails.error.report(RuntimeError.new("ledger:verify found #{problems.size} problem(s)"), handled: true, severity: :error) if problems.any?
    problems.size
  end
end
