class Session < ApplicationRecord
  ABSOLUTE_LIFETIME = 30.days
  IDLE_LIMIT = 14.days
  TOUCH_EVERY = 10.minutes

  belongs_to :user
  attr_reader :raw_token

  before_validation :issue_token, on: :create
  before_create { self.expires_at ||= Clock.now + ABSOLUTE_LIFETIME; self.last_seen_at ||= Clock.now }

  scope :expired, ->(now = Clock.now) { where("expires_at <= ? OR last_seen_at <= ?", now, now - IDLE_LIMIT) }
  scope :active, ->(now = Clock.now) { where("expires_at > ? AND last_seen_at > ?", now, now - IDLE_LIMIT) }

  # SES-01: only the SHA-256 digest is stored. The cookie carries the raw token.
  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)
  def self.find_by_token(token) = token.present? ? find_by(token_digest: digest(token)) : nil

  # SES-02
  def expired?(now = Clock.now) = expires_at <= now || last_seen_at <= now - IDLE_LIMIT

  def touch_seen!(now = Clock.now)
    update_columns(last_seen_at: now) if last_seen_at <= now - TOUCH_EVERY
  end

  private

  def issue_token
    @raw_token = SecureRandom.base58(32)
    self.token_digest = self.class.digest(@raw_token)
  end
end
