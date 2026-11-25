class User < ApplicationRecord
  has_secure_password
  has_one :account, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_many :watchlist_items, dependent: :destroy

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }
  validates :name, presence: true, length: { maximum: 80 }
  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true
  COMMON_PASSWORDS = %w[password 12345678 123456789 1234567890 qwertyui qwerty123 11111111 iloveyou password1 abc12345].freeze
  validate { errors.add(:password, "is too common, pick something harder to guess") if password.present? && COMMON_PASSWORDS.include?(password.downcase) }
  validate { errors.add(:password, "is too long (maximum is 72 bytes)") if password.present? && password.bytesize > 72 }
end
