# PRD v4: hashed + expiring sessions (SES-01/02), account lifecycle (SES-05..08, ADM-02), audit log (SEC-09),
# runtime settings for the trading kill switch (ADM-05). Expand-only: existing sessions keep working.
class V4MultiUser < ActiveRecord::Migration[8.1]
  def up
    add_column :sessions, :token_digest, :string
    add_column :sessions, :expires_at, :datetime
    add_column :sessions, :last_seen_at, :datetime
    add_column :sessions, :reauthenticated_at, :datetime
    execute <<~SQL
      UPDATE sessions
         SET token_digest = encode(sha256(convert_to(token, 'UTF8')), 'hex'),
             expires_at = created_at + interval '30 days',
             last_seen_at = updated_at
       WHERE token IS NOT NULL
    SQL
    execute "DELETE FROM sessions WHERE token_digest IS NULL"
    change_column_null :sessions, :token_digest, false
    change_column_null :sessions, :expires_at, false
    change_column_null :sessions, :last_seen_at, false
    change_column_null :sessions, :token, true
    execute "UPDATE sessions SET token = NULL" # the raw token is no longer stored anywhere
    remove_index :sessions, :token
    add_index :sessions, :token_digest, unique: true
    add_index :sessions, %i[user_id last_seen_at]
    add_index :sessions, :expires_at

    add_column :users, :verified_at, :datetime
    add_column :users, :deleted_at, :datetime
    add_column :users, :disabled_at, :datetime
    add_column :users, :admin, :boolean, null: false, default: false
    add_column :users, :notify_order_filled, :boolean, null: false, default: false
    add_column :users, :notify_order_rejected, :boolean, null: false, default: true

    create_table :audit_events do |t|
      t.bigint :user_id
      t.string :event, null: false
      t.string :ip_address
      t.string :user_agent
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :audit_events, :user_id
    add_index :audit_events, %i[event created_at]
    add_index :audit_events, :created_at

    create_table :settings do |t|
      t.string :key, null: false
      t.string :value
      t.timestamps
    end
    add_index :settings, :key, unique: true

    add_index :orders, %i[account_id status], name: "index_orders_on_account_id_and_status"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "sessions.token was wiped; users sign in again"
  end
end
