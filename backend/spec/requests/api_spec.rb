require "rails_helper"

RSpec.describe "API", type: :request do
  before { Clock.override = -> { BrokerHelpers::OPEN_TIME } }

  describe "auth and guards" do
    it "signup creates $100,000.00 and sets an HttpOnly cookie [AUTH-01, AUTH-05]" do
      api(:post, "/signup", { name: "A", email: "  Mixed@Example.COM ", password: "password123" })
      expect(response).to have_http_status(:created)
      expect(json[:account][:cash]).to eq("100000.00")
      expect(User.last.email).to eq("mixed@example.com")
      expect(response.headers["Set-Cookie"]).to match(/pb_session=.*httponly/i)
      expect(response.headers["Set-Cookie"]).to match(/samesite=lax/i)
    end

    it "rejects duplicate emails regardless of case [AUTH-02]" do
      sign_up!(email: "dup@example.com")
      api(:post, "/signup", { name: "A", email: "DUP@example.com", password: "password123" })
      expect(response).to have_http_status(422)
      expect(json[:error][:code]).to eq("validation_failed")
    end

    it "validates name and password length in bytes [AUTH-02]" do
      [ { name: "", email: "a@b.co", password: "password123" },
        { name: "x" * 81, email: "a@b.co", password: "password123" },
        { name: "A", email: "a@b.co", password: "short" },
        { name: "A", email: "a@b.co", password: "é" * 37 } ].each do |body|
        api(:post, "/signup", body)
        expect(response).to have_http_status(422), body.inspect
      end
      api(:post, "/signup", { name: "A", email: "ok@b.co", password: "a" * 72 })
      expect(response).to have_http_status(:created)
    end

    it "rejects very common passwords [AUTH-02]" do
      api(:post, "/signup", { name: "A", email: "c@b.co", password: "Password" })
      expect(response).to have_http_status(422)
    end

    it "gives the same error for unknown email and wrong password [AUTH-03]" do
      email = sign_up!
      sign_out!
      api(:post, "/session", { email: email, password: "wrongpass1" })
      a = [ response.status, json[:error] ]
      api(:post, "/session", { email: "nobody@example.com", password: "wrongpass1" })
      expect([ response.status, json[:error] ]).to eq(a)
      expect(a[1]).to include(code: "unauthenticated", message: "Incorrect email or password.")
    end

    it "rate limits login to 10 per 3 minutes per IP [AUTH-04]" do
      original = ApplicationController.cache_store
      ApplicationController.cache_store = ActiveSupport::Cache::MemoryStore.new
      11.times { api(:post, "/session", { email: "x@example.com", password: "nopenope1" }) }
      expect(response).to have_http_status(429)
      expect(json[:error][:code]).to eq("rate_limited")
    ensure
      ApplicationController.cache_store = original
    end

    it "logout deletes the server session so a replayed cookie gets 401 [AUTH-05]" do
      sign_up!
      cookie = response.headers["Set-Cookie"][/pb_session=[^;]+/]
      sign_out!
      expect(response).to have_http_status(:no_content)
      api(:get, "/me", nil, { "COOKIE" => cookie })
      expect(response).to have_http_status(401)
    end

    it "requires JSON content type on POST and Accept+origin on DELETE [AUTH-06]" do
      post "/api/v1/signup", params: { name: "A", email: "a@b.co", password: "password123" }
      expect(response).to have_http_status(415)
      expect(json[:error][:code]).to eq("unsupported_media_type")
      delete "/api/v1/session"
      expect(response).to have_http_status(415)
      delete "/api/v1/session", headers: { "ACCEPT" => "application/json", "ORIGIN" => "https://evil.example" }
      expect(response).to have_http_status(415)
      delete "/api/v1/session", headers: { "ACCEPT" => "application/json", "ORIGIN" => "http://localhost:5173" }
      expect(response).to have_http_status(:no_content)
    end

    it "returns 401 without a session on every protected endpoint [AUTH-07]" do
      [ [ :get, "/me" ], [ :get, "/portfolio" ], [ :get, "/portfolio/history" ], [ :get, "/orders" ], [ :post, "/orders" ],
        [ :get, "/watchlist" ], [ :post, "/watchlist" ], [ :delete, "/watchlist/AAPL" ], [ :get, "/deposits" ],
        [ :post, "/deposits" ], [ :post, "/account/reset" ], [ :get, "/assets" ], [ :get, "/assets/AAPL" ],
        [ :get, "/assets/AAPL/candles" ] ].each do |m, path|
        api(m, path, m == :post ? {} : nil)
        expect(response).to have_http_status(401), "#{m} #{path}"
        expect(json[:error][:code]).to eq("unauthenticated")
      end
    end

    it "serves market status without a session [CAL-05]" do
      api(:get, "/market/status")
      expect(response).to have_http_status(:ok)
      expect(json).to include(:open, :next_open, :next_close, :session, :early_close)
    end

    it "returns a bad-JSON error cleanly and never a stack trace [API-01]" do
      post "/api/v1/signup", params: "{nope", headers: ApiHelpers::JSON_HEADERS
      expect(response).to have_http_status(422)
      expect(json[:error][:code]).to eq("validation_failed")
    end

    it "returns code internal without internals on unexpected errors [API-01]" do
      sign_up!
      allow(Portfolios::Valuate).to receive(:call).and_raise("secret detail")
      api(:get, "/portfolio")
      expect(response).to have_http_status(500)
      expect(json[:error]).to eq(code: "internal", message: "Something went wrong. Please try again.")
    end
  end

  describe "orders" do
    before { with_asset(symbol: "AAPL", price: "100"); sign_up! }

    def order(body, key: "key-#{SecureRandom.hex(3)}") = api(:post, "/orders", body, { "Idempotency-Key" => key })

    it "fills, returns order + cash + position, and replays with 200 [ORD-24, ORD-25]" do
      order({ symbol: "AAPL", side: "buy", amount: "1000" }, key: "k1")
      expect(response).to have_http_status(:created)
      expect(json[:order]).to include(symbol: "AAPL", side: "buy", total: "1000.00", quantity: "10.00000000")
      expect(json[:cash]).to eq("99000.00")
      expect(json[:position]).to include(symbol: "AAPL", quantity: "10.00000000")
      first_id = json[:order][:id]
      order({ symbol: "AAPL", side: "buy", amount: "1000" }, key: "k1")
      expect(response).to have_http_status(:ok)
      expect(json[:order][:id]).to eq(first_id)
      expect(Order.count).to eq(1)
    end

    it "returns position null after a full close [ORD-25]" do
      order({ symbol: "AAPL", side: "buy", quantity: "2" })
      order({ symbol: "AAPL", side: "sell", sell_all: true })
      expect(response).to have_http_status(:created)
      expect(json[:position]).to be_nil
    end

    it "emits the documented error codes and statuses [API-01]" do
      post "/api/v1/orders", params: { symbol: "AAPL", side: "buy", amount: "5" }.to_json, headers: ApiHelpers::JSON_HEADERS
      expect([ response.status, json[:error][:code] ]).to eq([ 422, "idempotency_key_required" ])
      order({ symbol: "AAPL", side: "buy", amount: "1.234" })
      expect([ response.status, json[:error][:code] ]).to eq([ 422, "validation_failed" ])
      order({ symbol: "NOPE", side: "buy", amount: "5" })
      expect([ response.status, json[:error][:code] ]).to eq([ 404, "not_found" ])
      order({ symbol: "AAPL", side: "buy", amount: "0.5" })
      expect(json[:error][:code]).to eq("below_minimum")
      order({ symbol: "AAPL", side: "buy", amount: "999999" })
      expect(json[:error]).to include(code: "insufficient_funds")
      expect(json[:error][:details]).to eq(max_amount: "100000.00")
      order({ symbol: "AAPL", side: "sell", amount: "5" })
      expect(json[:error][:code]).to eq("insufficient_quantity")
      order({ symbol: "AAPL", side: "buy", amount: "5" }, key: "dupe"); order({ symbol: "AAPL", side: "buy", amount: "6" }, key: "dupe")
      expect([ response.status, json[:error][:code] ]).to eq([ 422, "idempotency_conflict" ])
      Clock.override = -> { Time.utc(2026, 3, 7, 16, 0, 0) }
      order({ symbol: "AAPL", side: "buy", amount: "5" })
      expect([ response.status, json[:order][:status] ]).to eq([ 201, "pending" ]) # QUE-01
      Clock.override = -> { BrokerHelpers::OPEN_TIME }
      Quote.update_all(as_of: BrokerHelpers::OPEN_TIME - 1.hour)
      order({ symbol: "AAPL", side: "buy", amount: "5" })
      expect([ response.status, json[:error][:code] ]).to eq([ 503, "price_unavailable" ])
    end

    it "lists orders newest first with filters and rejects bad filters [ORD-30]" do
      order({ symbol: "AAPL", side: "buy", quantity: "1" }); order({ symbol: "AAPL", side: "buy", quantity: "2" })
      order({ symbol: "AAPL", side: "sell", quantity: "1" })
      api(:get, "/orders")
      expect(json[:orders].map { |o| o[:side] }).to eq(%w[sell buy buy])
      expect(json[:orders].map { |o| o[:quantity] }.first).to eq("1.00000000")
      api(:get, "/orders?side=sell"); expect(json[:orders].size).to eq(1)
      api(:get, "/orders?symbol=aapl"); expect(json[:orders].size).to eq(3)
      api(:get, "/orders?side=short"); expect(response).to have_http_status(422)
      api(:get, "/orders?symbol=ZZZZ"); expect(response).to have_http_status(422)
      api(:get, "/orders?page=0"); expect(response).to have_http_status(422)
    end

    it "never exposes another user's orders or data [AUTH-07]" do
      order({ symbol: "AAPL", side: "buy", amount: "100" }, key: "shared-key")
      sign_out!; sign_up!
      api(:get, "/orders"); expect(json[:orders]).to be_empty
      api(:get, "/portfolio"); expect(json[:cash]).to eq("100000.00")
      api(:get, "/deposits"); expect(json[:deposits].size).to eq(1)
      order({ symbol: "AAPL", side: "buy", amount: "100" }, key: "shared-key") # same key, other account: a new order
      expect(response).to have_http_status(:created)
    end
  end

  describe "deposits, watchlist, reset" do
    before { with_asset(symbol: "AAPL"); sign_up! }

    it "deposits require a key, replay with 200, and conflict on a different body [DEP-02]" do
      api(:post, "/deposits", { amount: "5000" })
      expect(json[:error][:code]).to eq("idempotency_key_required")
      api(:post, "/deposits", { amount: "5000" }, { "Idempotency-Key" => "d" })
      expect(response).to have_http_status(:created)
      expect(json[:cash]).to eq("105000.00")
      api(:post, "/deposits", { amount: "5000" }, { "Idempotency-Key" => "d" })
      expect(response).to have_http_status(:ok)
      api(:post, "/deposits", { amount: "1" }, { "Idempotency-Key" => "d" })
      expect(json[:error][:code]).to eq("idempotency_conflict")
      api(:get, "/portfolio")
      expect(json[:total_return]).to eq("0.00")
    end

    it "watchlist add is idempotent, delete of an unwatched asset is 204 [WL-01]" do
      api(:post, "/watchlist", { symbol: "aapl" }); expect(response).to have_http_status(:created)
      api(:post, "/watchlist", { symbol: "AAPL" }); expect(response).to have_http_status(:ok)
      expect(WatchlistItem.count).to eq(1)
      api(:post, "/watchlist", { symbol: "NOPE" }); expect(response).to have_http_status(404)
      api(:delete, "/watchlist/AAPL"); expect(response).to have_http_status(:no_content)
      api(:delete, "/watchlist/AAPL"); expect(response).to have_http_status(:no_content)
    end

    it "reset requires the exact word [RST-01]" do
      api(:post, "/account/reset", { confirm: "reset" }); expect(response).to have_http_status(422)
      api(:post, "/account/reset", { confirm: "RESET" }); expect(response).to have_http_status(:ok)
      expect(json[:account][:cash]).to eq("100000.00")
    end
  end
end
