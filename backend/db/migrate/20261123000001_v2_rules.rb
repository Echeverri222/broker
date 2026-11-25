class V2Rules < ActiveRecord::Migration[8.1]
  def change
    # MON-07
    add_check_constraint :orders, "quantity > 0", name: "orders_quantity_pos"
    add_check_constraint :orders, "price > 0", name: "orders_price_pos"
    add_check_constraint :orders, "total > 0", name: "orders_total_pos"

    # ORD-24 / DEP-02: request hash to detect key reuse with a different body
    add_column :orders, :request_hash, :string
    add_column :deposits, :request_hash, :string

    # CA-02
    create_table :corporate_actions do |t|
      t.references :asset, null: false, foreign_key: true
      t.string :kind, null: false, default: "split"
      t.decimal :ratio, precision: 20, scale: 8, null: false
      t.date :effective_date, null: false
      t.timestamps
      t.index %i[asset_id kind effective_date], unique: true, name: "index_corporate_actions_unique"
      t.check_constraint "ratio > 0", name: "corporate_actions_ratio_pos"
    end

    # CA-03
    create_table :position_adjustments do |t|
      t.references :account, null: false, foreign_key: true
      t.references :asset, null: false, foreign_key: true
      t.references :corporate_action, null: false, foreign_key: true
      t.decimal :quantity_before, precision: 28, scale: 8, null: false
      t.decimal :quantity_after, precision: 28, scale: 8, null: false
      t.decimal :average_cost_before, precision: 20, scale: 8, null: false
      t.decimal :average_cost_after, precision: 20, scale: 8, null: false
      t.timestamps
      t.index %i[account_id corporate_action_id], unique: true, name: "index_position_adjustments_unique"
    end
  end
end
