class User < ApplicationRecord
  has_secure_password
  has_one :account, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_many :watchlist_items, dependent: :destroy

  # SES-05 / SES-07: stateless, signed, expiring tokens. The reset token is bound to the current password hash, so it
  # works once: changing the password invalidates it.
  generates_token_for :password_reset, expires_in: 30.minutes do
    password_salt&.last(10)
  end
  generates_token_for :email_verification, expires_in: 24.hours do
    email
  end

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }
  validates :name, presence: true, length: { maximum: 80 }
  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true
  COMMON_PASSWORDS = %w[password 12345678 123456789 1234567890 qwertyui qwerty123 11111111 iloveyou password1 abc12345].freeze
  validate { errors.add(:password, "is too common, pick something harder to guess") if password.present? && COMMON_PASSWORDS.include?(password.downcase) }
  validate { errors.add(:password, "is too long (maximum is 72 bytes)") if password.present? && password.bytesize > 72 }

  def verified? = verified_at.present?
  def deleted? = deleted_at.present?
  def disabled? = disabled_at.present?

  # SES-08: anonymise instead of erasing, so ledger rows (orders, deposits, snapshots) stay consistent for audit.
  # The account can no longer sign in: the email is gone and the password is a random value nobody knows.
  def anonymise!
    transaction do
      sessions.delete_all
      watchlist_items.delete_all
      update_columns(email: "deleted-#{id}@invalid", name: "Deleted user", password_digest: BCrypt::Password.create(SecureRandom.hex(32)),
                     deleted_at: Clock.now, verified_at: nil, notify_order_filled: false, notify_order_rejected: false, updated_at: Clock.now)
    end
  end
end
