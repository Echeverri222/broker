# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_26_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.decimal "cash", precision: 20, scale: 2, null: false
    t.datetime "reset_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_accounts_on_user_id", unique: true
    t.check_constraint "cash >= 0::numeric", name: "accounts_cash_nonneg"
  end

  create_table "assets", force: :cascade do |t|
    t.string "symbol", null: false
    t.string "name", null: false
    t.string "kind", null: false
    t.string "provider_ref"
    t.string "logo_url"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "sector"
    t.index ["symbol"], name: "index_assets_on_symbol", unique: true
    t.check_constraint "kind::text = ANY (ARRAY['stock'::character varying::text, 'etf'::character varying::text, 'crypto'::character varying::text])", name: "assets_kind_valid"
  end

  create_table "audit_events", force: :cascade do |t|
    t.bigint "user_id"
    t.string "event", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_audit_events_on_created_at"
    t.index ["event", "created_at"], name: "index_audit_events_on_event_and_created_at"
    t.index ["user_id"], name: "index_audit_events_on_user_id"
  end

  create_table "corporate_actions", force: :cascade do |t|
    t.bigint "asset_id", null: false
    t.string "kind", default: "split", null: false
    t.decimal "ratio", precision: 20, scale: 8, null: false
    t.date "effective_date", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["asset_id", "kind", "effective_date"], name: "index_corporate_actions_unique", unique: true
    t.index ["asset_id"], name: "index_corporate_actions_on_asset_id"
    t.check_constraint "ratio > 0::numeric", name: "corporate_actions_ratio_pos"
  end

  create_table "deposits", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.decimal "amount", precision: 20, scale: 2, null: false
    t.string "kind", default: "deposit", null: false
    t.string "idempotency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "request_hash"
    t.index ["account_id", "idempotency_key"], name: "index_deposits_on_account_id_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["account_id"], name: "index_deposits_on_account_id"
    t.check_constraint "amount > 0::numeric", name: "deposits_amount_pos"
    t.check_constraint "kind::text = ANY (ARRAY['initial'::character varying::text, 'deposit'::character varying::text])", name: "deposits_kind_valid"
  end

  create_table "orders", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "asset_id", null: false
    t.string "side", null: false
    t.decimal "quantity", precision: 28, scale: 8
    t.decimal "price", precision: 20, scale: 8
    t.decimal "total", precision: 20, scale: 2
    t.decimal "realized_pnl", precision: 20, scale: 2
    t.string "status", default: "filled", null: false
    t.string "reject_reason"
    t.string "idempotency_key"
    t.datetime "filled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "request_hash"
    t.decimal "amount", precision: 20, scale: 2
    t.decimal "requested_quantity", precision: 28, scale: 8
    t.boolean "sell_all", default: false, null: false
    t.decimal "reserved_cash", precision: 20, scale: 2, default: "0.0", null: false
    t.datetime "cancelled_at"
    t.index ["account_id", "created_at"], name: "index_orders_on_account_id_and_created_at"
    t.index ["account_id", "idempotency_key"], name: "index_orders_on_account_id_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["account_id", "status"], name: "index_orders_on_account_id_and_status"
    t.index ["account_id"], name: "index_orders_on_account_id"
    t.index ["asset_id"], name: "index_orders_on_asset_id"
    t.index ["status", "created_at"], name: "index_orders_pending", where: "((status)::text = 'pending'::text)"
    t.check_constraint "price > 0::numeric", name: "orders_price_pos"
    t.check_constraint "quantity > 0::numeric", name: "orders_quantity_pos"
    t.check_constraint "reserved_cash >= 0::numeric", name: "orders_reserved_nonneg"
    t.check_constraint "side::text = ANY (ARRAY['buy'::character varying::text, 'sell'::character varying::text])", name: "orders_side_valid"
    t.check_constraint "status::text <> 'filled'::text OR quantity IS NOT NULL AND price IS NOT NULL AND total IS NOT NULL", name: "orders_filled_complete"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'filled'::character varying, 'cancelled'::character varying, 'rejected'::character varying]::text[])", name: "orders_status_valid"
    t.check_constraint "total > 0::numeric", name: "orders_total_pos"
  end

  create_table "portfolio_snapshots", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.decimal "total_value", precision: 20, scale: 2, null: false
    t.decimal "cash", precision: 20, scale: 2, null: false
    t.decimal "invested_value", precision: 20, scale: 2, null: false
    t.decimal "net_deposits", precision: 20, scale: 2, default: "0.0", null: false
    t.datetime "taken_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "taken_at"], name: "index_portfolio_snapshots_on_account_id_and_taken_at"
  end

  create_table "position_adjustments", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "asset_id", null: false
    t.bigint "corporate_action_id", null: false
    t.decimal "quantity_before", precision: 28, scale: 8, null: false
    t.decimal "quantity_after", precision: 28, scale: 8, null: false
    t.decimal "average_cost_before", precision: 20, scale: 8, null: false
    t.decimal "average_cost_after", precision: 20, scale: 8, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "corporate_action_id"], name: "index_position_adjustments_unique", unique: true
    t.index ["account_id"], name: "index_position_adjustments_on_account_id"
    t.index ["asset_id"], name: "index_position_adjustments_on_asset_id"
    t.index ["corporate_action_id"], name: "index_position_adjustments_on_corporate_action_id"
  end

  create_table "positions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "asset_id", null: false
    t.decimal "quantity", precision: 28, scale: 8, null: false
    t.decimal "average_cost", precision: 20, scale: 8, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "asset_id"], name: "index_positions_on_account_id_and_asset_id", unique: true
    t.index ["account_id"], name: "index_positions_on_account_id"
    t.index ["asset_id"], name: "index_positions_on_asset_id"
    t.check_constraint "quantity > 0::numeric", name: "positions_quantity_pos"
  end

  create_table "quotes", force: :cascade do |t|
    t.bigint "asset_id", null: false
    t.decimal "price", precision: 20, scale: 8, null: false
    t.decimal "previous_close", precision: 20, scale: 8
    t.decimal "change_percent", precision: 12, scale: 4
    t.datetime "as_of", null: false
    t.datetime "fetched_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "stats"
    t.index ["asset_id"], name: "index_quotes_on_asset_id", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "token"
    t.string "user_agent"
    t.string "ip_address"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "last_seen_at", null: false
    t.datetime "reauthenticated_at"
    t.index ["expires_at"], name: "index_sessions_on_expires_at"
    t.index ["token_digest"], name: "index_sessions_on_token_digest", unique: true
    t.index ["user_id", "last_seen_at"], name: "index_sessions_on_user_id_and_last_seen_at"
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.string "key", null: false
    t.string "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.citext "email", null: false
    t.string "password_digest", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.datetime "deleted_at"
    t.datetime "disabled_at"
    t.boolean "admin", default: false, null: false
    t.boolean "notify_order_filled", default: false, null: false
    t.boolean "notify_order_rejected", default: true, null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  create_table "watchlist_items", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "asset_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["asset_id"], name: "index_watchlist_items_on_asset_id"
    t.index ["user_id", "asset_id"], name: "index_watchlist_items_on_user_id_and_asset_id", unique: true
    t.index ["user_id"], name: "index_watchlist_items_on_user_id"
  end

  add_foreign_key "accounts", "users"
  add_foreign_key "corporate_actions", "assets"
  add_foreign_key "deposits", "accounts"
  add_foreign_key "orders", "accounts"
  add_foreign_key "orders", "assets"
  add_foreign_key "portfolio_snapshots", "accounts"
  add_foreign_key "position_adjustments", "accounts"
  add_foreign_key "position_adjustments", "assets"
  add_foreign_key "position_adjustments", "corporate_actions"
  add_foreign_key "positions", "accounts"
  add_foreign_key "positions", "assets"
  add_foreign_key "quotes", "assets"
  add_foreign_key "sessions", "users"
  add_foreign_key "watchlist_items", "assets"
  add_foreign_key "watchlist_items", "users"
end
