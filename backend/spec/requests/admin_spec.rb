require "rails_helper"

# PRD v4 §12: admin tools, kill switch, health, notifications and calendar coverage (ADM-01..05, NTF-01..03, OBS-06, CAL-07).
RSpec.describe "Admin, operations and notifications [ADM, NTF, OBS, CAL]", type: :request do
  before { Clock.override = -> { BrokerHelpers::OPEN_TIME } }

  def admin_client
    c = client.sign_up
    make_admin!(c.email)
    c
  end

  def reauthed_admin
    c = admin_client
    expect(c.post("/admin/reauth", { password: "password123" }).status).to eq(200)
    c
  end

  describe "access and re-authentication [ADM-01]" do
    it "answers 401 anonymously and 404 to a non-admin, so the endpoints are not discoverable" do
      expect(client.get("/admin/users").status).to eq(401)
      expect(client.sign_up.get("/admin/users").status).to eq(404)
    end

    it "makes an admin confirm their password before any admin action" do
      c = admin_client
      expect(c.get("/admin/users").status).to eq(403)
      expect(c.code).to eq("reauth_required")
      expect(c.post("/admin/reauth", { password: "wrong-wrong" }).status).to eq(401)
      expect(c.post("/admin/reauth", { password: "password123" }).status).to eq(200)
      expect(c.get("/admin/users").status).to eq(200)
    end

    it "lets the re-authentication lapse after 15 minutes and only for that session" do
      c = reauthed_admin
      other_device = client.sign_in(c.email)
      expect(other_device.get("/admin/users").code).to eq("reauth_required")
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 16.minutes }
      expect(c.get("/admin/users").code).to eq("reauth_required")
    end

    it "does not let a non-admin reauth their way in" do
      u = client.sign_up
      expect(u.post("/admin/reauth", { password: "password123" }).status).to eq(404)
    end

    it "writes an audit event for every admin action" do
      c = reauthed_admin
      target = client.sign_up
      id = User.find_by!(email: target.email).id
      c.post("/admin/users/#{id}/disable")
      c.post("/admin/users/#{id}/enable")
      c.post("/admin/users/#{id}/revoke_sessions")
      c.post("/admin/users/#{id}/password_reset")
      c.patch("/admin/settings", { trading_enabled: false })
      expect(AuditEvent.pluck(:event)).to include("admin_reauth", "admin_user_disabled", "admin_user_enabled",
                                                 "admin_sessions_revoked", "password_reset_requested", "admin_trading_changed")
      expect(AuditEvent.find_by(event: "admin_user_disabled").metadata).to include("target_user_id" => id)
    end
  end

  describe "user management [ADM-02]" do
    let!(:admin) { reauthed_admin }
    let!(:target) { client.sign_up(email: "target@example.com") }
    let(:target_id) { User.find_by!(email: "target@example.com").id }

    it "finds users by email fragment, name or id and shows the account without secrets" do
      expect(admin.get("/admin/users?q=target@").json[:users].map { |u| u[:email] }).to eq([ "target@example.com" ])
      expect(admin.get("/admin/users?q=#{target_id}").json[:users].map { |u| u[:id] }).to eq([ target_id ])
      show = admin.get("/admin/users/#{target_id}").json
      expect(show).to include(email: "target@example.com", disabled: false, active_sessions: 1)
      expect(show[:account]).to include(cash: "100000.00", orders: 0)
      expect(show.to_s).not_to include("password_digest")
    end

    it "disables a user: they are signed out, cannot sign in, and get account_disabled" do
      expect(admin.post("/admin/users/#{target_id}/disable").json[:disabled]).to be(true)
      expect(target.get("/me").status).to eq(401)
      signin = client.sign_in("target@example.com")
      expect([ signin.status, signin.code ]).to eq([ 403, "account_disabled" ])
      expect(admin.post("/admin/users/#{target_id}/enable").json[:disabled]).to be(false)
      expect(client.sign_in("target@example.com").status).to eq(200)
    end

    it "blocks a disabled user who still holds a session" do
      session = Session.where(user_id: target_id).first
      User.find(target_id).update_columns(disabled_at: Clock.now)
      expect(target.get("/me").code).to eq("account_disabled")
      expect(session).to be_present
    end

    it "does not let an admin disable themselves" do
      id = User.find_by!(email: admin.email).id
      expect(admin.post("/admin/users/#{id}/disable").status).to eq(422)
      expect(User.find(id).disabled?).to be(false)
    end

    it "revokes a user's sessions without disabling them" do
      expect(admin.post("/admin/users/#{target_id}/revoke_sessions").json[:active_sessions]).to eq(0)
      expect(target.get("/me").status).to eq(401)
      expect(client.sign_in("target@example.com").status).to eq(200)
    end

    it "triggers a password reset mail but never reveals a token" do
      expect { admin.post("/admin/users/#{target_id}/password_reset") }.to have_enqueued_mail(UserMailer, :password_reset)
      expect(admin.status).to eq(202)
      expect(admin.body).to be_blank
    end

    it "has no way to change balances, positions or orders" do
      routes = Rails.application.routes.routes.select { |r| r.path.spec.to_s.include?("/admin/") }
      verbs_paths = routes.map { |r| "#{r.verb} #{r.path.spec}" }.join("\n")
      expect(verbs_paths).not_to match(/account|balance|cash|position|order|deposit/i)
      expect(admin.patch("/admin/users/#{target_id}", { cash: "999999" }).status).to eq(404)
    end

    it "gives 404 for an unknown user" do
      expect(admin.get("/admin/users/0").status).to eq(404)
    end
  end

  describe "kill switch [ADM-05]" do
    let!(:admin) { reauthed_admin }

    it "defaults to trading enabled and is switchable by an admin" do
      expect(admin.get("/admin/settings").json).to eq(trading_enabled: true)
      expect(admin.patch("/admin/settings", { trading_enabled: false }).json).to eq(trading_enabled: false)
      expect(admin.patch("/admin/settings", { trading_enabled: "maybe" }).status).to eq(422)
      expect(Setting.trading_enabled?).to be(false)
    end

    it "pauses new orders with 503 trading_paused, while reading and cancelling still work" do
      with_asset(symbol: "AAPL", price: "100")
      user = client.sign_up
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 10.hours } # closed, so the order waits
      Quote.update_all(as_of: Clock.now, fetched_at: Clock.now)
      queued = user.call(:post, "/orders", { symbol: "AAPL", side: "buy", amount: "100" }, { "Idempotency-Key" => "q1" })
      expect(queued.json[:order][:status]).to eq("pending")
      order_id = queued.json[:order][:id]

      admin.post("/admin/reauth", { password: "password123" }) # the clock moved on
      admin.patch("/admin/settings", { trading_enabled: false })
      paused = user.call(:post, "/orders", { symbol: "AAPL", side: "buy", amount: "50" }, { "Idempotency-Key" => "q2" })
      expect([ paused.status, paused.code ]).to eq([ 503, "trading_paused" ])
      expect(user.get("/orders").status).to eq(200)
      expect(user.get("/portfolio").status).to eq(200)
      expect(user.delete("/orders/#{order_id}").status).to be_between(200, 204)
    end

    it "stops fills too, and resumes them when switched back on" do
      with_asset(symbol: "AAPL", price: "100")
      u = create(:user)
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 10.hours }
      Quote.update_all(as_of: Clock.now, fetched_at: Clock.now)
      order = Orders::Place.call(account: u.account, symbol: "AAPL", side: "buy", amount: "100", idempotency_key: "w1").order
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 24.hours } # next open, 11:00 ET Tuesday
      Quote.update_all(as_of: Clock.now, fetched_at: Clock.now)
      Setting.set("trading_enabled", false)
      Orders::FillPending.call(account: u.account)
      expect(order.reload.status).to eq("pending")
      Setting.set("trading_enabled", true)
      Orders::FillPending.call(account: u.account)
      expect(order.reload.status).to eq("filled")
    end

    it "shows the flag to signed-in users so the SPA can show a banner" do
      Setting.set("trading_enabled", false)
      user = client.sign_up
      expect(user.get("/me").json[:trading_enabled]).to be(false)
    end
  end

  describe "asset switch [ADM-03]" do
    let!(:admin) { reauthed_admin }

    it "lists assets with quote age and provider, searchable and filterable" do
      with_asset(symbol: "AAPL", price: "100", fetched_at: Clock.now - 90.seconds)
      with_asset(symbol: "BTC", kind: "crypto", price: "50000")
      all = admin.get("/admin/assets").json[:assets]
      expect(all.map { |a| a[:symbol] }).to eq(%w[AAPL BTC])
      expect(all.first).to include(active: true, quote_age_seconds: 90, provider: "yahoo", held_by: 0)
      expect(all.last[:provider]).to eq("coingecko")
      expect(admin.get("/admin/assets?q=btc").json[:assets].size).to eq(1)
      expect(admin.get("/admin/assets?active=false").json[:assets]).to be_empty
    end

    it "disables an asset: buys are blocked, sells of an existing position still work, and it is audited" do
      with_asset(symbol: "AAPL", price: "100")
      holder = client.sign_up
      holder.call(:post, "/orders", { symbol: "AAPL", side: "buy", amount: "1000" }, { "Idempotency-Key" => "h1" })
      expect(holder.status).to eq(201)

      expect(admin.patch("/admin/assets/AAPL", { active: false }).json[:held_by]).to eq(1)
      expect(AuditEvent.find_by(event: "admin_asset_changed").metadata).to include("symbol" => "AAPL", "active" => false)

      buy = holder.call(:post, "/orders", { symbol: "AAPL", side: "buy", amount: "10" }, { "Idempotency-Key" => "h2" })
      expect([ buy.status, buy.code ]).to eq([ 422, "validation_failed" ])
      sell = holder.call(:post, "/orders", { symbol: "AAPL", side: "sell", sell_all: true }, { "Idempotency-Key" => "h3" })
      expect(sell.status).to eq(201)
      expect(Position.where(asset: Asset.find_by!(symbol: "AAPL")).sum(:quantity)).to eq(0)
    end

    it "hides a disabled asset from search and detail, and re-enabling restores buying" do
      with_asset(symbol: "AAPL", price: "100")
      user = client.sign_up
      admin.patch("/admin/assets/AAPL", { active: false })
      expect(user.get("/assets/AAPL").status).to eq(404)
      expect(user.get("/assets?q=AAPL").json[:assets]).to be_empty
      admin.patch("/admin/assets/AAPL", { active: true })
      expect(user.get("/assets/AAPL").status).to eq(200)
      expect(user.call(:post, "/orders", { symbol: "AAPL", side: "buy", amount: "10" }, { "Idempotency-Key" => "r1" }).status).to eq(201)
    end

    it "validates input and answers 404 for unknown symbols" do
      with_asset(symbol: "AAPL", price: "100")
      expect(admin.patch("/admin/assets/AAPL", { active: "no" }).status).to eq(422)
      expect(admin.patch("/admin/assets/ZZZZ", { active: false }).status).to eq(404)
    end
  end

  describe "queues and audit trail [ADM-04, SEC-09]" do
    let!(:admin) { reauthed_admin }

    it "reports queue depth and failed jobs, and never raises when the queue database is missing" do
      body = admin.get("/admin/queues").json
      expect(body).to include(:available, :depth, :failed)
      expect(body[:failed]).to be_an(Array)
    end

    it "answers 404 for a failed job that does not exist" do
      skip "queue database not available" unless QueueStats.available?
      expect(admin.post("/admin/jobs/0/retry").status).to eq(404)
    end

    it "lets an admin read the audit log, filtered by event and user" do
      u = client.sign_up(email: "audited@example.com")
      uid = User.find_by!(email: "audited@example.com").id
      events = admin.get("/admin/audit_events?user_id=#{uid}").json[:events]
      expect(events.map { |e| e[:event] }).to eq([ "signup" ])
      expect(admin.get("/admin/audit_events?event=admin_reauth").json[:events].size).to eq(1)
      expect(u.get("/admin/audit_events").status).to eq(404)
    end
  end

  describe "readiness [OBS-06]" do
    def deep(client_ = client) = client_.call(:get, "/../../up/deep").then { client_ }

    def get_deep
      get "/up/deep"
      [ response.status, JSON.parse(response.body) ]
    end

    it "is ok when the database, quotes, queue and calendar are healthy" do
      with_asset(symbol: "AAPL", price: "100")
      status, body = get_deep
      expect([ status, body["status"], body["problems"] ]).to eq([ 200, "ok", [] ])
    end

    it "reports stale quotes while the market is open, with a 503" do
      with_asset(symbol: "AAPL", price: "100", fetched_at: Clock.now - 10.minutes)
      status, body = get_deep
      expect(status).to eq(503)
      expect(body["problems"].join).to match(/quotes stale/)
    end

    it "does not complain about old quotes while the market is closed" do
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 10.hours }
      with_asset(symbol: "AAPL", price: "100", fetched_at: Clock.now - 2.hours)
      expect(get_deep.first).to eq(200)
    end

    it "reports a paused trading switch and an open provider circuit" do
      with_asset(symbol: "AAPL", price: "100")
      Setting.set("trading_enabled", false)
      MarketData::Gateway::FAILURE_LIMIT.times { MarketData::Gateway.call("yahoo") { raise MarketData::ProviderError, "boom" } rescue nil }
      problems = get_deep.last["problems"]
      expect(problems).to include("trading paused", "yahoo circuit open")
    end

    it "is cheap and public (no session, no user data)" do
      with_asset(symbol: "AAPL", price: "100")
      get "/up/deep"
      expect(response.body).not_to match(/email|cash|balance/i)
    end
  end

  describe "calendar coverage [CAL-07]" do
    it "warns when under 90 days remain and still trades stocks until the end of the range" do
      last = MarketCalendar::COVERED_THROUGH
      Clock.override = -> { Time.utc(last.year, last.month, last.day, 16) - 60.days }
      with_asset(symbol: "AAPL", price: "100")
      expect(MarketCalendar.days_remaining).to be < MarketCalendar::WARN_DAYS
      get "/up/deep"
      expect(JSON.parse(response.body)["problems"].join).to match(/market calendar ends in \d+ days/)
      expect(MarketCalendar.days_remaining).to be > 0
    end

    it "is quiet with plenty of coverage" do
      with_asset(symbol: "AAPL", price: "100")
      expect(MarketCalendar.days_remaining).to be >= MarketCalendar::WARN_DAYS
      get "/up/deep"
      expect(JSON.parse(response.body)["problems"].join).not_to match(/calendar/)
    end
  end

  describe "order notifications [NTF-01, NTF-02]" do
    let(:user) { create(:user) }

    def queued_order(side: "buy")
      with_asset(symbol: "AAPL", price: "100")
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 10.hours }
      Quote.update_all(as_of: Clock.now, fetched_at: Clock.now)
      Orders::Place.call(account: user.account, symbol: "AAPL", side: side, amount: "100", idempotency_key: "n#{SecureRandom.hex(3)}").order
    end

    def filled_order
      with_asset(symbol: "AAPL", price: "100") unless Asset.exists?(symbol: "AAPL")
      Clock.override = -> { BrokerHelpers::OPEN_TIME }
      Quote.update_all(as_of: Clock.now, fetched_at: Clock.now)
      Orders::Place.call(account: user.account, symbol: "AAPL", side: "buy", amount: "100", idempotency_key: "f#{SecureRandom.hex(3)}").order
    end

    it "emails a rejected queued order by default, and a filled one only when opted in" do
      order = queued_order
      order.update_columns(status: "rejected", reject_reason: "insufficient_cash")
      expect { OrderNotificationJob.perform_now(order.id) }.to change { ActionMailer::Base.deliveries.size }.by(1)
      expect(ActionMailer::Base.deliveries.last.subject).to match(/could not be filled/)

      order = filled_order
      expect { OrderNotificationJob.perform_now(order.id) }.not_to change { ActionMailer::Base.deliveries.size }
      user.update!(notify_order_filled: true)
      expect { OrderNotificationJob.perform_now(order.id) }.to change { ActionMailer::Base.deliveries.size }.by(1)
      expect(ActionMailer::Base.deliveries.last.subject).to match(/was filled/)
    end

    it "respects an opt-out of rejected mail and never mails deleted or disabled users" do
      order = queued_order
      order.update_columns(status: "rejected")
      user.update!(notify_order_rejected: false)
      expect { OrderNotificationJob.perform_now(order.id) }.not_to change { ActionMailer::Base.deliveries.size }
      user.update!(notify_order_rejected: true)
      user.update_columns(disabled_at: Clock.now)
      expect { OrderNotificationJob.perform_now(order.id) }.not_to change { ActionMailer::Base.deliveries.size }
    end

    it "ignores orders that no longer exist and orders still pending" do
      order = queued_order
      expect { OrderNotificationJob.perform_now(order.id) }.not_to change { ActionMailer::Base.deliveries.size }
      expect { OrderNotificationJob.perform_now(0) }.not_to raise_error
    end

    it "enqueues a notification when a waiting order settles, and not for an order filled immediately" do
      order = queued_order
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 24.hours }
      Quote.update_all(as_of: Clock.now, fetched_at: Clock.now)
      expect { Orders::FillPending.call(account: user.account) }.to have_enqueued_job(OrderNotificationJob).with(order.id)

      Clock.override = -> { BrokerHelpers::OPEN_TIME }
      Quote.update_all(as_of: Clock.now, fetched_at: Clock.now)
      expect { Orders::Place.call(account: user.account, symbol: "AAPL", side: "buy", amount: "10", idempotency_key: "now1") }
        .not_to have_enqueued_job(OrderNotificationJob)
    end

    it "contains no balances or secrets and is plain text" do
      order = filled_order
      mail = UserMailer.order_filled(order)
      expect(mail.content_type).to match(%r{text/plain})
      expect(mail.body.to_s).not_to match(/password|token|cash/i)
    end

    it "offers only the five transactional emails: no marketing, no push, no SMS [NTF-03]" do
      expect(UserMailer.action_methods.sort).to eq(%w[order_filled order_rejected password_changed password_reset verify_email])
      expect(User.column_names.grep(/marketing|sms|push|newsletter/i)).to be_empty
      expect(Dir[Rails.root.join("app/mailers/*.rb")].map { |f| File.basename(f) }).to contain_exactly("application_mailer.rb", "user_mailer.rb")
    end

    it "sends password mail without the old password and with a single-purpose link" do
      expect(UserMailer.password_changed(user).body.to_s).not_to include("password123")
      expect(UserMailer.verify_email(user).body.to_s).to match(%r{/verify-email\?token=})
    end
  end
end
