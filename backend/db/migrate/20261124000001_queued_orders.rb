class QueuedOrders < ActiveRecord::Migration[8.1]
  def change
    change_column_null :orders, :quantity, true
    change_column_null :orders, :price, true
    change_column_null :orders, :total, true
    add_column :orders, :amount, :decimal, precision: 20, scale: 2            # dollars the user asked for
    add_column :orders, :requested_quantity, :decimal, precision: 28, scale: 8 # shares/coins the user asked for
    add_column :orders, :sell_all, :boolean, default: false, null: false
    add_column :orders, :reserved_cash, :decimal, precision: 20, scale: 2, default: 0, null: false
    add_column :orders, :cancelled_at, :datetime

    remove_check_constraint :orders, name: "orders_status_valid"
    add_check_constraint :orders, "status IN ('pending','filled','cancelled','rejected')", name: "orders_status_valid"
    add_check_constraint :orders, "status <> 'filled' OR (quantity IS NOT NULL AND price IS NOT NULL AND total IS NOT NULL)", name: "orders_filled_complete"
    add_check_constraint :orders, "reserved_cash >= 0", name: "orders_reserved_nonneg"
    add_index :orders, [ :status, :created_at ], where: "status = 'pending'", name: "index_orders_pending"
  end
end
