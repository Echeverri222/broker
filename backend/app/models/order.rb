class Order < ApplicationRecord
  belongs_to :account
  belongs_to :asset

  STATUSES = %w[pending filled cancelled rejected].freeze
  scope :pending, -> { where(status: "pending") }

  # ORD-23: only a pending order may change (to filled / cancelled / rejected). Everything else is immutable.
  before_update { raise ActiveRecord::ReadOnlyRecord, "Settled orders cannot be changed" unless status_in_database == "pending" }
  before_destroy(prepend: true) { throw :abort unless destroyed_by_association }
end
