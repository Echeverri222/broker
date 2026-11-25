class Account < ApplicationRecord
  belongs_to :user
  has_many :positions, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :deposits, dependent: :destroy
  has_many :portfolio_snapshots, dependent: :destroy

  # QUE-04: cash set aside for queued buys; it cannot be spent twice.
  def reserved_cash = orders.pending.sum(:reserved_cash)
  def available_cash = cash - reserved_cash

  def net_deposits = deposits.sum(:amount)
  def benchmark_start = reset_at || created_at
  def self.starting_cash = BigDecimal(ENV.fetch("STARTING_CASH", "100000"))
end
