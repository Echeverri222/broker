# SEC-09: append-only record of security-relevant events. Rows are never updated or deleted by the app.
class AuditEvent < ApplicationRecord
  EVENTS = %w[signup login_success login_failure logout password_changed password_reset_requested password_reset
              email_verified session_revoked sessions_revoked account_deleted account_reset
              admin_user_disabled admin_user_enabled admin_sessions_revoked admin_trading_changed admin_reauth
              admin_job_retried admin_job_discarded].freeze

  belongs_to :user, optional: true
  validates :event, inclusion: { in: EVENTS }

  before_update { raise ActiveRecord::ReadOnlyRecord, "audit events are append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "audit events are append-only" }

  def self.record(event, user: nil, ip: nil, user_agent: nil, **metadata)
    create!(event: event, user_id: user&.id, ip_address: ip, user_agent: user_agent&.first(255), metadata: metadata)
  end
end
