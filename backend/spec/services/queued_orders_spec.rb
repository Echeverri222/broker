require "rails_helper"

RSpec.describe "Queued orders [QUE]" do
  let(:user) { create(:user) }
  let(:account) { user.account }
  let(:closed) { Time.utc(2026, 3, 7, 16, 0, 0) }   # Saturday
  let(:open_t) { Time.utc(2026, 3, 9, 14, 0, 0) }   # Monday 10:00 ET
  let(:seq) { (1..1000).each }

  def at(time) = Clock.override = -> { time }

  # Move to the open with a current quote, as the quote job would have produced.
  def open!(price = nil)
    at(open_t)
    Quote.update_all(as_of: open_t, fetched_at: open_t)
    Quote.update_all(price: BigDecimal(price)) if price
  end

  def place(sym: "AAPL", side: "buy", key: "k#{seq.next}", **kw)
    Orders::Place.call(account: account, symbol: sym, side: side, idempotency_key: key, **kw)
  end

  def error_of(&blk)
    blk.call
    nil
  rescue ApiError => e
    e
  end

  before do
    at(closed)
    with_asset(price: "100")
  end

  it "stores a pending order and reserves the dollars [QUE-01, QUE-04]" do
    o = place(amount: "1000").order
    expect(o).to have_attributes(status: "pending", reserved_cash: BigDecimal("1000"), price: nil)
    expect(account.reload).to have_attributes(cash: BigDecimal("100000"), reserved_cash: BigDecimal("1000"), available_cash: BigDecimal("99000"))
  end

  it "reserves 105% for quantity-sized buys [QUE-04]" do
    expect(place(quantity: "10").order.reserved_cash).to eq(BigDecimal("1050.00"))
  end

  it "does not let reserved cash be spent twice [QUE-04]" do
    place(amount: "60000")
    e = error_of { place(amount: "50000") }
    expect(e.code).to eq(:insufficient_funds)
    expect(e.details[:max_amount]).to eq("40000.00")
  end

  it "replays and detects conflicts like instant orders [QUE-02]" do
    first = place(amount: "50", key: "same")
    again = place(amount: "50", key: "same")
    expect([ again.created, again.order.id ]).to eq([ false, first.order.id ])
    expect(error_of { place(amount: "60", key: "same") }.code).to eq(:idempotency_conflict)
    expect(account.orders.pending.count).to eq(1)
  end

  it "validates at queue time [QUE-03]" do
    expect(error_of { place(amount: "0.50") }.code).to eq(:below_minimum)
    expect(error_of { place(side: "sell", quantity: "1") }.code).to eq(:insufficient_quantity)
    Quote.delete_all
    expect(error_of { place(quantity: "1") }.code).to eq(:price_unavailable)
    expect(place(amount: "25").order.status).to eq("pending") # dollars need no price
  end

  it "limits sells to what is held and to one waiting sell per asset [QUE-05]" do
    open!; place(quantity: "10"); at(closed)
    expect(error_of { place(side: "sell", quantity: "11") }.code).to eq(:insufficient_quantity)
    place(side: "sell", quantity: "4")
    expect(error_of { place(side: "sell", sell_all: true) }.code).to eq(:insufficient_quantity)
  end

  it "caps waiting orders at 20 [QUE-05]" do
    20.times { place(amount: "1") }
    expect(error_of { place(amount: "1") }.code).to eq(:too_many_pending_orders)
  end

  it "fills at the open at the then-current price, oldest first [QUE-06, QUE-09]" do
    a = place(amount: "1000").order
    b = place(amount: "500").order
    at(open_t)
    Quote.update_all(price: BigDecimal("125"), as_of: open_t, fetched_at: open_t)
    expect(Orders::FillPending.call).to eq(2)
    expect(a.reload).to have_attributes(status: "filled", price: BigDecimal("125"), quantity: BigDecimal("8"), total: BigDecimal("1000"), reserved_cash: 0)
    expect(b.reload.status).to eq("filled")
    expect(account.reload).to have_attributes(cash: BigDecimal("98500"), reserved_cash: 0)
    expect(account.positions.first.quantity).to eq(BigDecimal("12"))
    expect(Ledger::Verify.call).to be_empty
  end

  it "does nothing while the market is closed or the price is not current yet [QUE-06]" do
    o = place(amount: "100").order
    expect(Orders::FillPending.call).to eq(0)
    at(open_t)
    Quote.update_all(as_of: open_t - 2.days, fetched_at: open_t - 2.days)
    allow(MarketData).to receive(:quote).and_raise(MarketData::ProviderError, "down")
    expect(Orders::FillPending.call).to eq(0)
    expect(o.reload.status).to eq("pending")
  end

  it "fills a queued sell-all against the position held at the open [QUE-06]" do
    open!; place(quantity: "10"); at(closed)
    s = place(side: "sell", sell_all: true).order
    at(open_t)
    Quote.update_all(price: BigDecimal("110"), as_of: open_t, fetched_at: open_t)
    Orders::FillPending.call
    expect(s.reload).to have_attributes(status: "filled", total: BigDecimal("1100"), realized_pnl: BigDecimal("100"))
    expect(account.reload.positions).to be_empty
  end

  it "rejects with a reason when the price gapped beyond the reservation [QUE-08]" do
    o = place(quantity: "10").order # reserved 1050 at $100
    at(open_t)
    Quote.update_all(price: BigDecimal("200"), as_of: open_t, fetched_at: open_t)
    # Another instant purchase of crypto uses up the rest of the cash.
    account.update!(cash: 1050)
    Orders::FillPending.call
    expect(o.reload).to have_attributes(status: "rejected", reserved_cash: 0)
    expect(o.reject_reason).to match(/Not enough cash/)
    expect(account.reload.cash).to eq(1050)
  end

  it "cancels, releases the reservation, repeats safely, and refuses settled orders [QUE-07]" do
    o = place(amount: "700").order
    expect(Orders::Cancel.call(account: account, id: o.id)).to have_attributes(status: "cancelled", reserved_cash: 0)
    expect(account.reload.available_cash).to eq(100_000)
    expect(Orders::Cancel.call(account: account, id: o.id).status).to eq("cancelled")
    open!
    filled = place(amount: "10").order
    expect(filled.status).to eq("filled")
    expect(error_of { Orders::Cancel.call(account: account, id: filled.id) }.code).to eq(:order_not_pending)
    expect(error_of { Orders::Cancel.call(account: account, id: 0) }.code).to eq(:not_found)
  end

  it "keeps settled orders immutable [ORD-23, QUE-09]" do
    open!
    o = place(amount: "10").order
    expect { o.update!(total: 1) }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
