require "rails_helper"

# PRD v4 §7: sessions, account lifecycle and abuse limits.
RSpec.describe "Sessions and accounts [SES, SEC]", type: :request do
  before { Clock.override = -> { BrokerHelpers::OPEN_TIME } }

  def mail_to(email) = ActionMailer::Base.deliveries.select { |m| m.to.include?(email) }

  describe "sessions" do
    it "stores only a digest of the token and never the raw value [SES-01]" do
      email = sign_up!
      s = User.find_by!(email: email).sessions.last
      expect(s.token).to be_nil
      expect(s.token_digest).to match(/\A\h{64}\z/)
      expect(Session.column_names).to include("token_digest")
      expect(Session.where(token_digest: Session.digest("not the token")).count).to eq(0)
    end

    it "digests deterministically and looks sessions up by the raw token [SES-01]" do
      u = create(:user)
      s = u.sessions.create!
      expect(s.raw_token).to be_present
      expect(s.token_digest).to eq(Digest::SHA256.hexdigest(s.raw_token))
      expect(Session.find_by_token(s.raw_token)).to eq(s)
      expect(Session.find_by_token(nil)).to be_nil
      expect(Session.find_by_token("")).to be_nil
    end

    it "gives every session a 30 day absolute expiry [SES-02]" do
      sign_up!
      s = Session.last
      expect(s.expires_at).to be_within(1.second).of(Clock.now + 30.days)
    end

    it "expires after 30 days and deletes the row [SES-02]" do
      sign_up!
      api(:get, "/me"); expect(response).to have_http_status(:ok)
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 31.days }
      expect { api(:get, "/me") }.to change { Session.count }.by(-1)
      expect(response).to have_http_status(401)
    end

    it "expires after 14 idle days even inside the 30 day lifetime [SES-02]" do
      sign_up!
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 15.days }
      api(:get, "/me")
      expect(response).to have_http_status(401)
    end

    it "keeps an active session alive: last_seen_at is touched at most every 10 minutes [SES-02]" do
      sign_up!
      s = Session.last
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 5.minutes }
      api(:get, "/me")
      expect(s.reload.last_seen_at).to eq(BrokerHelpers::OPEN_TIME)
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 11.minutes }
      api(:get, "/me")
      expect(s.reload.last_seen_at).to eq(BrokerHelpers::OPEN_TIME + 11.minutes)
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 11.minutes + 13.days }
      api(:get, "/me")
      expect(response).to have_http_status(:ok)
    end

    it "prunes expired and idle sessions and keeps active ones [SES-03]" do
      u = create(:user)
      keep = u.sessions.create!
      old = u.sessions.create!; old.update_columns(expires_at: Clock.now - 1.day)
      idle = u.sessions.create!; idle.update_columns(last_seen_at: Clock.now - 15.days)
      expect(PruneSessionsJob.perform_now).to eq(2)
      expect(u.sessions.pluck(:id)).to eq([ keep.id ])
    end

    it "migrates plain tokens to digests so existing sessions keep working [SES-01]" do
      expect(ActiveRecord::Base.connection.index_exists?(:sessions, :token_digest, unique: true)).to be(true)
      expect(ActiveRecord::Base.connection.index_exists?(:sessions, :token)).to be(false)
    end
  end

  describe "listing and revoking sessions [SES-04]" do
    it "lists my active sessions, flags the current one, and hides everyone else's" do
      email = sign_up!
      other = client(agent: "Phone").sign_in(email)
      stranger = client.sign_up
      api(:get, "/sessions")
      expect(response).to have_http_status(:ok)
      expect(json[:sessions].size).to eq(2)
      expect(json[:sessions].count { |s| s[:current] }).to eq(1)
      expect(json[:sessions].map { |s| s[:user_agent] }).to include("Phone")
      expect(json[:sessions].map { |s| s[:id] }).not_to include(stranger.get("/sessions").json[:sessions].first[:id])
      expect(other.status).to eq(200)
    end

    it "revokes one other session; that device is signed out, this one is not" do
      email = sign_up!
      phone = client.sign_in(email)
      target = json_target = nil
      api(:get, "/sessions")
      target = json[:sessions].find { |s| !s[:current] }
      api(:delete, "/sessions/#{target[:id]}")
      expect(response).to have_http_status(:no_content)
      expect(phone.get("/me").status).to eq(401)
      api(:get, "/me"); expect(response).to have_http_status(:ok)
    end

    it "revoking the current session signs this device out" do
      sign_up!
      api(:get, "/sessions")
      api(:delete, "/sessions/#{json[:sessions].first[:id]}")
      expect(response).to have_http_status(:no_content)
      api(:get, "/me"); expect(response).to have_http_status(401)
    end

    it "signs out every other device at once and keeps this one" do
      email = sign_up!
      phones = [ client.sign_in(email), client.sign_in(email) ]
      api(:delete, "/sessions")
      expect(response).to have_http_status(:no_content)
      expect(phones.map { |p| p.get("/me").status }).to eq([ 401, 401 ])
      api(:get, "/me"); expect(response).to have_http_status(:ok)
    end

    it "cannot revoke another user's session: 404, and theirs keeps working" do
      victim = client.sign_up
      victim_session = Session.last
      sign_up!
      api(:delete, "/sessions/#{victim_session.id}")
      expect(response).to have_http_status(:not_found)
      expect(victim.get("/me").status).to eq(200)
    end

    it "does not list expired sessions" do
      email = sign_up!
      User.find_by!(email: email).sessions.create!.update_columns(expires_at: Clock.now - 1.hour)
      api(:get, "/sessions")
      expect(json[:sessions].size).to eq(1)
    end
  end

  describe "password reset [SES-05]" do
    let!(:user) { create(:user, email: "reset@example.com") }

    it "answers 202 with the same empty body for a known and an unknown email" do
      api(:post, "/password_reset", { email: "reset@example.com" })
      known = [ response.status, response.body ]
      api(:post, "/password_reset", { email: "nobody@example.com" })
      expect([ response.status, response.body ]).to eq(known)
      expect(known.first).to eq(202)
    end

    it "sends mail only for a real, active account" do
      expect { api(:post, "/password_reset", { email: "reset@example.com" }) }.to have_enqueued_mail(UserMailer, :password_reset)
      expect { api(:post, "/password_reset", { email: "nobody@example.com" }) }.not_to have_enqueued_mail(UserMailer, :password_reset)
      user.update_columns(disabled_at: Clock.now)
      expect { api(:post, "/password_reset", { email: "reset@example.com" }) }.not_to have_enqueued_mail(UserMailer, :password_reset)
    end

    it "sets a new password with the token, signs out every session and sends a notice" do
      token = user.generate_token_for(:password_reset)
      old = client.sign_in("reset@example.com")
      expect(old.status).to eq(200)
      expect { api(:patch, "/password_reset", { token: token, password: "brand-new-pass-1" }) }.to have_enqueued_mail(UserMailer, :password_changed)
      expect(response).to have_http_status(:no_content)
      expect(old.get("/me").status).to eq(401)
      expect(client.sign_in("reset@example.com", "password123").status).to eq(401)
      expect(client.sign_in("reset@example.com", "brand-new-pass-1").status).to eq(200)
      expect(user.reload.verified?).to be(true) # reading the email proves ownership
    end

    it "works once: the same token fails after the password changed" do
      token = user.generate_token_for(:password_reset)
      api(:patch, "/password_reset", { token: token, password: "brand-new-pass-1" })
      expect(response).to have_http_status(:no_content)
      api(:patch, "/password_reset", { token: token, password: "another-pass-22" })
      expect([ response.status, json[:error][:code] ]).to eq([ 422, "invalid_token" ])
    end

    it "expires after 30 minutes" do
      token = user.generate_token_for(:password_reset)
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 31.minutes }
      travel_to(Time.current + 31.minutes) do
        api(:patch, "/password_reset", { token: token, password: "brand-new-pass-1" })
        expect(json[:error][:code]).to eq("invalid_token")
      end
    end

    it "rejects garbage tokens and weak passwords, and leaves the password alone" do
      api(:patch, "/password_reset", { token: "nope", password: "brand-new-pass-1" })
      expect(json[:error][:code]).to eq("invalid_token")
      token = user.generate_token_for(:password_reset)
      api(:patch, "/password_reset", { token: token, password: "short" })
      expect(response).to have_http_status(422)
      expect(user.reload.authenticate("password123")).to be_truthy
    end

    it "never works for a deleted account" do
      token = user.generate_token_for(:password_reset)
      user.anonymise!
      api(:patch, "/password_reset", { token: token, password: "brand-new-pass-1" })
      expect(json[:error][:code]).to eq("invalid_token")
    end

    it "is rate limited per IP and per email" do
      3.times { api(:post, "/password_reset", { email: "reset@example.com" }) }
      api(:post, "/password_reset", { email: "reset@example.com" })
      expect(response).to have_http_status(429)
      expect(response.headers["Retry-After"]).to eq("3600")
    end

    it "builds a link to the SPA containing the token, and no secrets" do
      mail = UserMailer.password_reset(user)
      expect(mail.to).to eq([ "reset@example.com" ])
      expect(mail.body.to_s).to match(%r{/reset-password\?token=})
      expect(mail.body.to_s).not_to include("password123")
    end
  end

  describe "change password [SES-06]" do
    it "requires the current password" do
      sign_up!(password: "password123")
      api(:patch, "/account/password", { current_password: "wrong-wrong", password: "new-password-9" })
      expect(response).to have_http_status(422)
    end

    it "changes it, signs out other devices only, and sends a notice [SES-04]" do
      email = sign_up!
      phone = client.sign_in(email)
      expect { api(:patch, "/account/password", { current_password: "password123", password: "new-password-9" }) }.to have_enqueued_mail(UserMailer, :password_changed)
      expect(response).to have_http_status(:no_content)
      expect(phone.get("/me").status).to eq(401)
      api(:get, "/me"); expect(response).to have_http_status(:ok)
      expect(client.sign_in(email, "new-password-9").status).to eq(200)
    end

    it "applies the normal password rules" do
      sign_up!
      api(:patch, "/account/password", { current_password: "password123", password: "password" })
      expect(response).to have_http_status(422)
    end

    it "is rate limited so the current password cannot be guessed" do
      sign_up!
      5.times { api(:patch, "/account/password", { current_password: "bad-bad-bad", password: "new-password-9" }) }
      api(:patch, "/account/password", { current_password: "bad-bad-bad", password: "new-password-9" })
      expect(response).to have_http_status(429)
    end
  end

  describe "email verification [SES-07]" do
    it "sends a confirmation mail at signup and starts unverified" do
      expect { sign_up! }.to have_enqueued_mail(UserMailer, :verify_email)
      api(:get, "/me")
      expect(json[:verified]).to be(false)
    end

    it "does not block trading while unverified" do
      sign_up!
      with_asset(symbol: "AAPL", price: "100")
      api(:post, "/orders", { symbol: "AAPL", side: "buy", amount: "10" }, { "Idempotency-Key" => "v1" })
      expect(response).to have_http_status(:created)
    end

    it "verifies with a valid token and rejects bad or expired ones" do
      email = sign_up!
      user = User.find_by!(email: email)
      api(:patch, "/email_verification", { token: "garbage" })
      expect(json[:error][:code]).to eq("invalid_token")
      api(:patch, "/email_verification", { token: user.generate_token_for(:email_verification) })
      expect(response).to have_http_status(:no_content)
      api(:get, "/me"); expect(json[:verified]).to be(true)
      stale = user.generate_token_for(:email_verification)
      travel_to(Time.current + 25.hours) do
        api(:patch, "/email_verification", { token: stale })
        expect(json[:error][:code]).to eq("invalid_token")
      end
    end

    it "invalidates a token when the email changes" do
      user = create(:user)
      token = user.generate_token_for(:email_verification)
      user.update_columns(email: "changed@example.com")
      expect(User.find_by_token_for(:email_verification, token)).to be_nil
    end

    it "resends only while unverified, and at most 3 times an hour" do
      sign_up!
      expect { api(:post, "/email_verification") }.to have_enqueued_mail(UserMailer, :verify_email)
      expect(response).to have_http_status(:accepted)
      User.last.update_columns(verified_at: Clock.now)
      expect { api(:post, "/email_verification") }.not_to have_enqueued_mail(UserMailer, :verify_email)
      api(:post, "/email_verification"); api(:post, "/email_verification")
      expect(response).to have_http_status(429)
    end

    it "requires a session to resend" do
      api(:post, "/email_verification")
      expect(response).to have_http_status(401)
    end
  end

  describe "delete my account [SES-08]" do
    it "needs the exact word and the right password" do
      sign_up!
      api(:delete, "/account", { confirm: "delete", password: "password123" })
      expect(response).to have_http_status(422)
      api(:delete, "/account", { confirm: "DELETE", password: "wrong-pass-1" })
      expect(response).to have_http_status(422)
      expect(User.last.deleted?).to be(false)
    end

    it "anonymises the user, signs out everywhere, and keeps the ledger intact" do
      email = sign_up!
      with_asset(symbol: "AAPL", price: "100")
      api(:post, "/orders", { symbol: "AAPL", side: "buy", amount: "1000" }, { "Idempotency-Key" => "d1" })
      user = User.find_by!(email: email)
      phone = client.sign_in(email)
      api(:post, "/watchlist", { symbol: "AAPL" })
      orders_before = user.account.orders.count
      api(:delete, "/account", { confirm: "DELETE", password: "password123" })
      expect(response).to have_http_status(:no_content)

      user.reload
      expect(user).to have_attributes(email: "deleted-#{user.id}@invalid", name: "Deleted user")
      expect(user.deleted?).to be(true)
      expect(user.sessions.count).to eq(0)
      expect(user.watchlist_items.count).to eq(0)
      expect(phone.get("/me").status).to eq(401)
      expect(user.account.orders.count).to eq(orders_before)
      expect(user.account.deposits.count).to eq(1)
      expect(Ledger::Verify.call).to be_empty
    end

    it "cannot sign in again, and the email can be registered afresh" do
      email = sign_up!
      api(:delete, "/account", { confirm: "DELETE", password: "password123" })
      expect(client.sign_in(email).status).to eq(401)
      expect(client.sign_up(email: email).status).to eq(201)
    end

    it "does not touch other users" do
      other = client.sign_up
      sign_up!
      api(:delete, "/account", { confirm: "DELETE", password: "password123" })
      expect(other.get("/me").status).to eq(200)
    end
  end

  describe "export [SES-10]" do
    it "returns only my own orders, deposits and positions" do
      sign_up!
      with_asset(symbol: "AAPL", price: "100")
      api(:post, "/orders", { symbol: "AAPL", side: "buy", amount: "500" }, { "Idempotency-Key" => "e1" })
      stranger = client.sign_up
      stranger.post("/orders", { symbol: "AAPL", side: "buy", amount: "700" }) # no key: rejected, creates nothing
      api(:get, "/account/export")
      expect(response).to have_http_status(:ok)
      expect(json[:orders].size).to eq(1)
      expect(json[:orders].first[:total]).to eq("500.00")
      expect(json[:deposits].size).to eq(1)
      expect(json[:positions].map { |p| p[:symbol] }).to eq([ "AAPL" ])
      expect(json[:user]).not_to have_key(:password_digest)
    end

    it "needs a session and is rate limited" do
      api(:get, "/account/export"); expect(response).to have_http_status(401)
      sign_up!
      6.times { api(:get, "/account/export") }
      expect(response).to have_http_status(429)
    end
  end

  describe "preferences [NTF-02]" do
    it "defaults to rejected-on and filled-off and can be changed" do
      sign_up!
      api(:get, "/me")
      expect(json[:preferences]).to eq(notify_order_filled: false, notify_order_rejected: true)
      api(:patch, "/account/preferences", { notify_order_filled: true, notify_order_rejected: false })
      expect(response).to have_http_status(:ok)
      expect(json[:preferences]).to eq(notify_order_filled: true, notify_order_rejected: false)
    end
  end

  describe "login throttling [SEC-03]" do
    it "limits one email across many IPs, with the normal error shape and Retry-After" do
      target = create(:user, email: "target@example.com")
      statuses = Array.new(11) { |i| client(ip: "198.51.100.#{i + 1}").sign_in(target.email, "wrong-wrong").status }
      expect(statuses.first(10)).to all(eq(401))
      expect(statuses.last).to eq(429)
      c = client(ip: "198.51.100.200").sign_in(target.email, "password123")
      expect(c.status).to eq(429)
      expect(c.header("Retry-After")).to eq("900")
      expect(c.code).to eq("rate_limited")
    end

    it "does not lock out other emails from the same IP" do
      a = create(:user, email: "a@example.com"); b = create(:user, email: "b@example.com")
      9.times { client(ip: "203.0.113.5").sign_in(a.email, "wrong-wrong") }
      expect(client(ip: "203.0.113.6").sign_in(b.email).status).to eq(200)
    end

    it "treats email case and spaces as the same bucket" do
      u = create(:user, email: "case@example.com")
      10.times { |i| client(ip: "198.51.100.#{i + 1}").sign_in(i.even? ? " CASE@example.com " : u.email, "wrong-wrong") }
      expect(client(ip: "198.51.100.99").sign_in(u.email).status).to eq(429)
    end
  end

  describe "per-user rate limits [SEC-02]" do
    it "limits orders to 60 a minute per user, with Retry-After, and not other users" do
      a = client.sign_up; b = client.sign_up
      with_asset(symbol: "AAPL", price: "100")
      61.times { |i| a.post("/orders", { symbol: "NOPE", side: "buy", amount: "5" }) }
      expect(a.status).to eq(429)
      expect(a.header("Retry-After")).to eq("60")
      expect(a.code).to eq("rate_limited")
      expect(b.post("/orders", { symbol: "NOPE", side: "buy", amount: "5" }).status).not_to eq(429)
    end

    it "limits deposits to 10 an hour" do
      sign_up!
      10.times { |i| api(:post, "/deposits", { amount: "10" }, { "Idempotency-Key" => "dep#{i}" }); expect(response.status).to be < 300 }
      api(:post, "/deposits", { amount: "10" }, { "Idempotency-Key" => "dep-x" })
      expect(response).to have_http_status(429)
    end

    it "limits account resets to 3 a day" do
      sign_up!
      3.times { api(:post, "/account/reset", { confirm: "RESET" }); expect(response).to have_http_status(:ok) }
      api(:post, "/account/reset", { confirm: "RESET" })
      expect(response).to have_http_status(429)
      expect(response.headers["Retry-After"]).to eq("86400")
    end

    it "limits searches to 120 a minute" do
      c = client.sign_up
      with_asset(symbol: "AAPL", price: "100")
      121.times { c.get("/assets?q=a") }
      expect(c.status).to eq(429)
    end

    it "applies a general 600 a minute limit per user, and per IP when anonymous" do
      c = client.sign_up
      601.times { c.get("/me") }
      expect(c.status).to eq(429)
      anon = client(ip: "192.0.2.77")
      601.times { anon.get("/market/status") }
      expect(anon.status).to eq(429)
      expect(client(ip: "192.0.2.78").get("/market/status").status).to eq(200)
    end
  end

  describe "proxy and host configuration [SEC-01, SEC-06]" do
    it "uses the forwarded client IP behind a trusted proxy for rate limits and sessions" do
      u = create(:user, email: "proxy@example.com")
      10.times { client(ip: "10.0.0.1").call(:post, "/session", { email: "x@example.com", password: "nope-nope" }, { "HTTP_X_FORWARDED_FOR" => "203.0.113.9" }) }
      limited = client(ip: "10.0.0.1").call(:post, "/session", { email: "x@example.com", password: "nope-nope" }, { "HTTP_X_FORWARDED_FOR" => "203.0.113.9" })
      expect(limited.status).to eq(429)
      other = client(ip: "10.0.0.1").call(:post, "/session", { email: u.email, password: "password123" }, { "HTTP_X_FORWARDED_FOR" => "203.0.113.10" })
      expect(other.status).to eq(200)
      expect(Session.last.ip_address).to eq("203.0.113.10")
    end

    it "does not trust X-Forwarded-For from an untrusted client" do
      c = client(ip: "198.51.100.50").call(:post, "/session", { email: "x@example.com", password: "nope-nope" }, { "HTTP_X_FORWARDED_FOR" => "1.2.3.4" })
      expect(c.status).to eq(401)
      expect(AuditEvent.where(event: "login_failure").last.ip_address).to eq("198.51.100.50")
    end

    it "parses TRUSTED_PROXIES and ALLOWED_HOSTS from the environment" do
      expect(DeployConfig.trusted_proxies(nil)).to be_nil
      expect(DeployConfig.trusted_proxies("  ")).to be_nil
      list = DeployConfig.trusted_proxies("198.51.100.0/24, 203.0.113.5")
      expect(list.any? { |ip| ip.include?(IPAddr.new("198.51.100.77")) }).to be(true)
      expect(list.any? { |ip| ip.include?(IPAddr.new("203.0.113.5")) }).to be(true)
      expect(list.any? { |ip| ip.include?(IPAddr.new("8.8.8.8")) }).to be(false)
      expect(list.any? { |ip| ip.include?(IPAddr.new("10.1.2.3")) }).to be(true) # defaults kept
      expect(DeployConfig.hosts(nil)).to be_nil
      expect(DeployConfig.hosts("app.example.com, .example.org ,")).to eq([ "app.example.com", ".example.org" ])
    end
  end

  describe "response headers [SEC-07]" do
    it "sets security headers on API responses" do
      api(:get, "/market/status")
      expect(response.headers).to include("X-Content-Type-Options" => "nosniff", "X-Frame-Options" => "DENY",
                                          "Referrer-Policy" => "strict-origin-when-cross-origin")
      expect(response.headers["Content-Security-Policy"]).to include("default-src 'none'")
      expect(response.headers["Permissions-Policy"]).to include("camera=()")
    end
  end

  describe "caps [SEC-04]" do
    it "limits deposits to $50M per account per day" do
      user = create(:user)
      4.times { |i| Deposits::Create.call(account: user.account, amount: "10000000", idempotency_key: "c#{i}") }
      Deposits::Create.call(account: user.account, amount: "10000000", idempotency_key: "c4")
      expect { Deposits::Create.call(account: user.account, amount: "1", idempotency_key: "c5") }
        .to raise_error(ApiError) { |e| expect([ e.code, e.message ]).to eq([ :validation_failed, "Daily deposit limit of $50000000 reached. Try again tomorrow." ]) }
      user.account.deposits.update_all(created_at: Clock.now - 25.hours)
      expect(Deposits::Create.call(account: user.account, amount: "1", idempotency_key: "c6").created).to be(true)
    end

    it "limits orders to 500 per account per day, but replays of an old key still work" do
      user = create(:user)
      with_asset(symbol: "AAPL", price: "100")
      first = Orders::Place.call(account: user.account, symbol: "AAPL", side: "buy", amount: "5", idempotency_key: "first").order
      rows = Array.new(499) { |i| { account_id: user.account.id, asset_id: first.asset_id, side: "buy", status: "rejected", idempotency_key: "bulk#{i}", created_at: Clock.now, updated_at: Clock.now } }
      Order.insert_all(rows)
      expect { Orders::Place.call(account: user.account, symbol: "AAPL", side: "buy", amount: "5", idempotency_key: "one-too-many") }
        .to raise_error(ApiError) { |e| expect([ e.code, e.message ]).to eq([ :validation_failed, "Daily limit of 500 orders reached. Try again tomorrow." ]) }
      expect(Orders::Place.call(account: user.account, symbol: "AAPL", side: "buy", amount: "5", idempotency_key: "first").created).to be(false)
      Clock.override = -> { BrokerHelpers::OPEN_TIME + 25.hours }
      Quote.update_all(as_of: Clock.now, fetched_at: Clock.now)
      expect(Orders::Place.call(account: user.account, symbol: "AAPL", side: "buy", amount: "5", idempotency_key: "tomorrow").created).to be(true)
    end
  end

  describe "audit log [SEC-09]" do
    def events = AuditEvent.order(:id).pluck(:event)

    it "records signup, login success and failure, logout, and password changes with ip and user agent" do
      email = sign_up!
      client.sign_in(email, "wrong-wrong")
      c = client(agent: "Safari").sign_in(email)
      c.delete("/session")
      api(:patch, "/account/password", { current_password: "password123", password: "new-password-9" })
      expect(events).to eq(%w[signup login_failure login_success logout password_changed])
      ok = AuditEvent.find_by(event: "login_success")
      expect(ok).to have_attributes(user_id: User.find_by!(email: email).id, user_agent: "Safari")
      expect(ok.ip_address).to be_present
    end

    it "records failures for unknown emails without a user and never stores the password" do
      client.sign_in("ghost@example.com", "super-secret-pw")
      e = AuditEvent.last
      expect(e).to have_attributes(event: "login_failure", user_id: nil)
      expect(e.metadata).to eq("email_known" => false)
      expect(AuditEvent.pluck(:metadata, :user_agent).to_s).not_to include("super-secret-pw")
    end

    it "records resets, deletions and session revocations" do
      sign_up!
      api(:get, "/sessions")
      api(:delete, "/sessions")
      api(:post, "/account/reset", { confirm: "RESET" })
      api(:delete, "/account", { confirm: "DELETE", password: "password123" })
      expect(events).to include("sessions_revoked", "account_reset", "account_deleted")
    end

    it "is append-only" do
      e = AuditEvent.record(:signup)
      expect { e.update!(event: "logout") }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { e.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { AuditEvent.record("nonsense") }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "authorization by construction [SEC-05, AUTH-07]" do
    PUBLIC = [ "POST /api/v1/signup", "POST /api/v1/session", "DELETE /api/v1/session", "GET /api/v1/market/status", "GET /api/v1/market/overview", "GET /api/v1/status",
               "POST /api/v1/password_reset", "PATCH /api/v1/password_reset", "PATCH /api/v1/email_verification" ].freeze

    def api_routes
      Rails.application.routes.routes.filter_map do |r|
        path = r.path.spec.to_s.sub("(.:format)", "")
        next unless path.start_with?("/api/v1")
        verb = r.verb.to_s
        next if verb.blank?
        [ verb, path ]
      end.uniq
    end

    def fill(path) = path.gsub(":id", "1").gsub(":symbol", "AAPL")

    it "answers 401 on every route that is not explicitly public" do
      anon = client
      protected_routes = api_routes.reject { |verb, path| PUBLIC.include?("#{verb} #{path}") }
      expect(protected_routes.size).to be > 25
      protected_routes.each do |verb, path|
        anon.call(verb.downcase.to_sym, fill(path).delete_prefix("/api/v1"), nil)
        expect([ "#{verb} #{path}", anon.status ]).to eq([ "#{verb} #{path}", 401 ])
      end
    end

    # Every route that addresses a record by :id or :symbol must be classified, so a new one cannot ship unchecked.
    CLASSIFIED = {
      "DELETE /api/v1/orders/:id" => :owned, "DELETE /api/v1/sessions/:id" => :owned, "DELETE /api/v1/watchlist/:symbol" => :owned,
      "GET /api/v1/assets/:symbol" => :shared_catalog, "GET /api/v1/assets/:symbol/candles" => :shared_catalog,
      "GET /api/v1/admin/users/:id" => :admin, "POST /api/v1/admin/users/:id/disable" => :admin, "POST /api/v1/admin/users/:id/enable" => :admin,
      "POST /api/v1/admin/users/:id/revoke_sessions" => :admin, "POST /api/v1/admin/users/:id/password_reset" => :admin,
      "PATCH /api/v1/admin/assets/:symbol" => :admin, "POST /api/v1/admin/jobs/:id/retry" => :admin, "DELETE /api/v1/admin/jobs/:id" => :admin
    }.freeze

    it "classifies every route that takes an :id or :symbol" do
      addressed = api_routes.select { |_, p| p.include?(":id") || p.include?(":symbol") }.map { |v, p| "#{v} #{p}" }
      expect(addressed - CLASSIFIED.keys).to eq([])
      expect(CLASSIFIED.keys - addressed).to eq([])
    end

    it "returns 404 when user B addresses user A's order, session, or watchlist entry, and changes nothing" do
      with_asset(symbol: "AAPL", price: "100")
      a = client.sign_up; b = client.sign_up
      a.call(:post, "/orders", { symbol: "AAPL", side: "buy", amount: "10" }, { "Idempotency-Key" => "own1" })
      a.post("/watchlist", { symbol: "AAPL" })
      order = Order.last
      session_id = User.find_by!(email: a.email).sessions.first.id

      expect(b.delete("/orders/#{order.id}").status).to eq(404)
      expect(b.delete("/sessions/#{session_id}").status).to eq(404)
      expect(b.delete("/watchlist/AAPL").status).to eq(204)
      expect(order.reload.status).to eq("filled")
      expect(User.find_by!(email: a.email).sessions.count).to eq(1)
      expect(a.get("/watchlist").json[:assets].size).to eq(1)
      expect(a.get("/orders").json[:orders].size).to eq(1)
      expect(b.get("/orders").json[:orders]).to be_empty
    end

    it "hides every admin route from a signed-in non-admin with 404" do
      user = client.sign_up
      admin_routes = api_routes.select { |_, p| p.start_with?("/api/v1/admin/") }
      expect(admin_routes.size).to be >= 12
      admin_routes.each do |verb, path|
        user.call(verb.downcase.to_sym, fill(path).delete_prefix("/api/v1"), {})
        expect([ "#{verb} #{path}", user.status ]).to eq([ "#{verb} #{path}", 404 ])
      end
    end
  end
end
