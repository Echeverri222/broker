class CreateCoreTables < ActiveRecord::Migration[8.1]
  def change
    enable_extension "citext"

    create_table :users do |t|
      t.citext :email, null: false
      t.string :password_digest, null: false
      t.string :name, null: false
      t.timestamps
    end
    add_index :users, :email, unique: true

    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token, null: false
      t.string :user_agent
      t.string :ip_address
      t.timestamps
    end
    add_index :sessions, :token, unique: true

    create_table :accounts do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.decimal :cash, precision: 20, scale: 2, null: false
      t.datetime :reset_at
      t.timestamps
    end
    add_check_constraint :accounts, "cash >= 0", name: "accounts_cash_nonneg"

    create_table :deposits do |t|
      t.references :account, null: false, foreign_key: true
      t.decimal :amount, precision: 20, scale: 2, null: false
      t.string :kind, null: false, default: "deposit"
      t.string :idempotency_key
      t.timestamps
    end
    add_index :deposits, [ :account_id, :idempotency_key ], unique: true, where: "idempotency_key IS NOT NULL"
    add_check_constraint :deposits, "amount > 0", name: "deposits_amount_pos"
    add_check_constraint :deposits, "kind IN ('initial','deposit')", name: "deposits_kind_valid"

    create_table :assets do |t|
      t.string :symbol, null: false
      t.string :name, null: false
      t.string :kind, null: false
      t.string :provider_ref
      t.string :logo_url
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :assets, :symbol, unique: true
    add_check_constraint :assets, "kind IN ('stock','etf','crypto')", name: "assets_kind_valid"

    create_table :quotes do |t|
      t.references :asset, null: false, foreign_key: true, index: { unique: true }
      t.decimal :price, precision: 20, scale: 8, null: false
      t.decimal :previous_close, precision: 20, scale: 8
      t.decimal :change_percent, precision: 12, scale: 4
      t.datetime :as_of, null: false
      t.datetime :fetched_at, null: false
      t.timestamps
    end

    create_table :positions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :asset, null: false, foreign_key: true
      t.decimal :quantity, precision: 28, scale: 8, null: false
      t.decimal :average_cost, precision: 20, scale: 8, null: false
      t.timestamps
    end
    add_index :positions, [ :account_id, :asset_id ], unique: true
    add_check_constraint :positions, "quantity > 0", name: "positions_quantity_pos"

    create_table :orders do |t|
      t.references :account, null: false, foreign_key: true
      t.references :asset, null: false, foreign_key: true
      t.string :side, null: false
      t.decimal :quantity, precision: 28, scale: 8, null: false
      t.decimal :price, precision: 20, scale: 8, null: false
      t.decimal :total, precision: 20, scale: 2, null: false
      t.decimal :realized_pnl, precision: 20, scale: 2
      t.string :status, null: false, default: "filled"
      t.string :reject_reason
      t.string :idempotency_key
      t.datetime :filled_at
      t.timestamps
    end
    add_index :orders, [ :account_id, :idempotency_key ], unique: true, where: "idempotency_key IS NOT NULL"
    add_index :orders, [ :account_id, :created_at ]
    add_check_constraint :orders, "side IN ('buy','sell')", name: "orders_side_valid"
    add_check_constraint :orders, "status IN ('filled','rejected')", name: "orders_status_valid"

    create_table :portfolio_snapshots do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.decimal :total_value, precision: 20, scale: 2, null: false
      t.decimal :cash, precision: 20, scale: 2, null: false
      t.decimal :invested_value, precision: 20, scale: 2, null: false
      t.decimal :net_deposits, precision: 20, scale: 2, null: false, default: 0
      t.datetime :taken_at, null: false
      t.timestamps
    end
    add_index :portfolio_snapshots, [ :account_id, :taken_at ]

    create_table :watchlist_items do |t|
      t.references :user, null: false, foreign_key: true
      t.references :asset, null: false, foreign_key: true
      t.timestamps
    end
    add_index :watchlist_items, [ :user_id, :asset_id ], unique: true
  end
end
