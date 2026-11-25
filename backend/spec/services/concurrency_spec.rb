require "rails_helper"

# Real threads and DB connections: no transactional fixtures here.
RSpec.describe "concurrency", type: :model do
  self.use_transactional_tests = false

  before do
    Clock.override = -> { BrokerHelpers::OPEN_TIME }
    @user = create(:user)
    @account = @user.account
    @asset = with_asset(symbol: "CONC", price: "100")
  end

  after do
    [ PortfolioSnapshot, Order, Position, Deposit, Quote, WatchlistItem, Account, Session, User, Asset ].each(&:delete_all)
  end

  def run_parallel(n, &blk)
    results = Array.new(n)
    threads = Array.new(n) do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          results[i] = begin
            blk.call(i)
          rescue ApiError => e
            e.code
          end
        end
      end
    end
    threads.each(&:join)
    results
  end

  it "10 parallel $20k buys on $100k give exactly 5 fills and cash 0 [ORD-21]" do
    res = run_parallel(10) { |i| Orders::Place.call(account: Account.find(@account.id), symbol: "CONC", side: "buy", amount: "20000", idempotency_key: "c#{i}") }
    expect(res.count { |r| r.respond_to?(:created) }).to eq(5)
    expect(res.count { |r| r == :insufficient_funds }).to eq(5)
    expect(@account.reload.cash).to eq(0)
    expect(Ledger::Verify.call).to be_empty
  end

  it "10 parallel sells of half the position give exactly 2 fills [ORD-21]" do
    Orders::Place.call(account: @account, symbol: "CONC", side: "buy", quantity: "10", idempotency_key: "seed")
    res = run_parallel(10) { |i| Orders::Place.call(account: Account.find(@account.id), symbol: "CONC", side: "sell", quantity: "5", idempotency_key: "s#{i}") }
    expect(res.count { |r| r.respond_to?(:created) }).to eq(2)
    expect(res.count { |r| r == :insufficient_quantity }).to eq(8)
    expect(Position.count).to eq(0)
    expect(Ledger::Verify.call).to be_empty
  end

  it "parallel requests with the same key create one order [ORD-24]" do
    res = run_parallel(8) { Orders::Place.call(account: Account.find(@account.id), symbol: "CONC", side: "buy", amount: "100", idempotency_key: "same") }
    expect(res.count { |r| r.respond_to?(:created) && r.created }).to eq(1)
    expect(Order.count).to eq(1)
    expect(@account.reload.cash).to eq(99_900)
  end

  it "a deposit in parallel with a buy keeps the ledger consistent [MON-05]" do
    run_parallel(6) do |i|
      acct = Account.find(@account.id)
      if i.even? then Deposits::Create.call(account: acct, amount: "500", idempotency_key: "d#{i}")
      else Orders::Place.call(account: acct, symbol: "CONC", side: "buy", amount: "1000", idempotency_key: "b#{i}")
      end
    end
    expect(Ledger::Verify.call).to be_empty
  end
end
