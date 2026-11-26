# DR-02: hourly read-only check of MON-05/MON-06 in production. A mismatch is reported (error tracker / alert).
# Only account ids and rule ids are logged, never balances.
class LedgerVerifyJob < ApplicationJob
  queue_as :low

  def perform
    problems = Ledger::Verify.call
    problems.each { |p| Rails.logger.error("ledger mismatch account=#{p[:account_id]} rule=#{p[:rule]}") }
    Rails.error.report(RuntimeError.new("ledger:verify found #{problems.size} problem(s)"), handled: true, severity: :error) if problems.any?
    Setting.set("ledger_verify_problems", problems.size) # exported as a metric for the page alert (OBS-04)
    Setting.set("ledger_verified_at", Clock.now.to_i)
    problems.size
  end
end
