import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter } from "react-router-dom";
import { axe } from "vitest-axe";
import { TradeSheet } from "./TradeSheet";
import { ApiError, type AssetDetail } from "../lib/api";

// A plain recorder instead of vi.fn(): vitest's spy wrapper re-throws rejected promises as unhandled errors.
const calls: unknown[][] = [];
let impl: (...a: unknown[]) => Promise<unknown> = async () => { throw new Error("no impl"); };
let marketOpen = true;
const resolveWith = (v: unknown) => { impl = async () => v; };
const rejectWith = (e: Error) => { impl = async () => { throw e; }; };
vi.mock("../lib/api", async (orig) => {
  const real = await orig<typeof import("../lib/api")>();
  return {
    ...real,
    api: {
      ...real.api,
      portfolio: async () => ({ cash: "1000.00", net_deposits: "1000.00", total_value: "1000.00", invested_value: "0.00", day_change: "0.00", day_change_percent: "0.00", total_return: "0.00", total_return_percent: "0.00", incomplete: false, positions: [] }),
      marketStatus: async () => ({ open: marketOpen, next_open: "2026-11-24T14:30:00Z", next_close: "2026-11-24T21:00:00Z", session: marketOpen ? "regular" : "closed", early_close: false }),
      placeOrder: (...a: unknown[]) => { calls.push(a); return impl(...a); },
    },
  };
});

const asset: AssetDetail = {
  symbol: "AAPL", name: "Apple Inc.", kind: "stock", logo_url: null, watched: false, sector: "Technology",
  stats: { open: null, day_low: null, day_high: null, week52_low: null, week52_high: null, volume: null, avg_volume: null, change_1m_percent: null, change_1y_percent: null },
  quote: { price: "100.00000000", previous_close: "99.00000000", change: "1.00000000", change_percent: "1.01", as_of: new Date().toISOString(), fetched_at: new Date().toISOString(), stale: false },
  position: { quantity: "10.00000000", average_cost: "90.00000000", market_value: "1000.00" },
};

const filled = {
  order: { id: 1, symbol: "AAPL", name: "Apple Inc.", kind: "stock", side: "buy", quantity: "9.99999999", price: "100.00000000", total: "1000.00", realized_pnl: null, status: "filled", filled_at: new Date().toISOString() },
  cash: "0.00", position: null,
};

function setup(side: "buy" | "sell" = "buy") {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const utils = render(
    <QueryClientProvider client={qc}><MemoryRouter><TradeSheet asset={asset} initialSide={side} onClose={() => {}} /></MemoryRouter></QueryClientProvider>,
  );
  return { user: userEvent.setup(), ...utils };
}

async function reviewAndConfirm(user: ReturnType<typeof userEvent.setup>, value: string) {
  await user.type(screen.getByLabelText(/amount \(usd\)/i), value);
  await user.click(screen.getByRole("button", { name: /^(buy|sell|queue (buy|sell).*)$/i }));
  await user.click(await screen.findByRole("button", { name: /confirm buy/i }));
}

describe("TradeSheet", () => {
  beforeEach(() => { calls.length = 0; marketOpen = true; });

  it("labels the live estimate and shows the actual server fill on the receipt [UX-01, UX-07]", async () => {
    resolveWith(filled);
    const { user } = setup();
    await user.type(screen.getByLabelText(/amount \(usd\)/i), "1000");
    expect(screen.getByText(/you'll get about/i)).toBeTruthy();
    expect(screen.getByText(/estimated total/i)).toBeTruthy();
    await user.click(screen.getByRole("button", { name: /^(buy|sell|queue (buy|sell).*)$/i }));
    await user.click(await screen.findByRole("button", { name: /confirm buy/i }));
    expect(await screen.findByText(/order filled/i)).toBeTruthy();
    expect(screen.getByText("9.99999999 AAPL")).toBeTruthy(); // actual, not estimated (10 AAPL)
    expect(screen.getByText(/Simulated fill at last price\. Virtual money\./)).toBeTruthy();
    expect(calls[0][0]).toEqual({ symbol: "AAPL", side: "buy", amount: "1000" });
  });

  it("blocks input the API would reject, without a request [ORD-02]", async () => {
    const { user } = setup();
    await user.type(screen.getByLabelText(/amount \(usd\)/i), "1.234");
    await user.click(screen.getByRole("button", { name: /^(buy|sell|queue (buy|sell).*)$/i }));
    expect((await screen.findByRole("alert")).textContent).toMatch(/dollars and cents/i);
    expect(calls.length).toBe(0);
  });

  it("disables Confirm while pending, so a double click sends one request with one key [UX-02]", async () => {
    let resolve!: (v: unknown) => void;
    impl = () => new Promise((r) => (resolve = r));
    const { user } = setup();
    await user.type(screen.getByLabelText(/amount \(usd\)/i), "50");
    await user.click(screen.getByRole("button", { name: /^(buy|sell|queue (buy|sell).*)$/i }));
    const confirm = await screen.findByRole("button", { name: /confirm buy/i });
    await user.dblClick(confirm);
    expect(calls.length).toBe(1);
    expect((screen.getByRole("button", { name: /placing/i }) as HTMLButtonElement).disabled).toBe(true);
    resolve(filled);
    await screen.findByText(/order filled/i);
  });

  it("reuses the idempotency key when retrying the same inputs, and changes it when they change [UX-02]", async () => {
    rejectWith(new ApiError("price_unavailable", "Price is temporarily unavailable.", 503));
    const { user } = setup();
    await reviewAndConfirm(user, "50");
    await waitFor(() => expect(calls.length).toBe(1));
    await user.click(await screen.findByRole("button", { name: /^(buy|sell|queue (buy|sell).*)$/i }));
    await user.click(await screen.findByRole("button", { name: /confirm buy/i }));
    await waitFor(() => expect(calls.length).toBe(2));
    expect(calls[1][1]).toBe(calls[0][1]);
    await user.type(screen.getByLabelText(/amount \(usd\)/i), "1");
    await user.click(screen.getByRole("button", { name: /^(buy|sell|queue (buy|sell).*)$/i }));
    await user.click(await screen.findByRole("button", { name: /confirm buy/i }));
    await waitFor(() => expect(calls.length).toBe(3));
    expect(calls[2][1]).not.toBe(calls[0][1]);
  });

  it("offers one-tap 'Use maximum' for insufficient funds [UX-03]", async () => {
    rejectWith(new ApiError("insufficient_funds", "Not enough cash.", 422, { max_amount: "1000.00" }));
    const { user } = setup();
    await reviewAndConfirm(user, "5000");
    await user.click(await screen.findByRole("button", { name: /use maximum \$1,000\.00/i }));
    expect((screen.getByLabelText(/amount \(usd\)/i) as HTMLInputElement).value).toBe("1000.00");
  });

  it("offers 'Sell all' on insufficient quantity and sends sell_all [UX-03, ORD-05]", async () => {
    rejectWith(new ApiError("insufficient_quantity", "You only hold 10.", 422, { max_quantity: "10.00000000", max_amount: "1000.00" }));
    const { user } = setup("sell");
    await user.type(screen.getByLabelText(/amount \(usd\)/i), "5000");
    await user.click(screen.getByRole("button", { name: /^(buy|sell|queue (buy|sell).*)$/i }));
    await user.click(await screen.findByRole("button", { name: /confirm sell/i }));
    await user.click(await screen.findByRole("button", { name: /sell all/i }));
    resolveWith({ ...filled, order: { ...filled.order, side: "sell" } });
    await user.click(screen.getByRole("button", { name: /^(buy|sell|queue (buy|sell).*)$/i }));
    await user.click(await screen.findByRole("button", { name: /confirm sell/i }));
    await waitFor(() => expect(calls.length).toBe(2));
    expect(calls[1][0]).toEqual({ symbol: "AAPL", side: "sell", sell_all: true });
  });

  it("has no serious accessibility violations [UX-08]", async () => {
    const { container } = setup();
    const results = await axe(container);
    const bad = results.violations.filter((v) => v.impact === "serious" || v.impact === "critical");
    expect(bad).toEqual([]);
  });

  it("queues a stock order while the market is closed and says nothing has been bought yet [QUE-01, UX-04]", async () => {
    marketOpen = false;
    resolveWith({ order: { ...filled.order, status: "pending", quantity: null, price: null, total: null, filled_at: null, amount: "1000.00", requested_quantity: null, sell_all: false, reserved_cash: "1000.00", reject_reason: null, created_at: new Date().toISOString() }, cash: "1000.00", reserved_cash: "1000.00", position: null });
    const { user } = setup();
    await user.type(screen.getByLabelText(/amount \(usd\)/i), "1000");
    await user.click(screen.getByRole("button", { name: /^(buy|sell|queue (buy|sell).*)$/i }));
    expect(screen.getByText(/market is closed, so this order will be queued/i)).toBeTruthy();
    await user.click(await screen.findByRole("button", { name: /queue buy/i }));
    expect(await screen.findByText(/order queued/i)).toBeTruthy();
    expect(screen.getByText(/nothing has been bought or sold yet/i)).toBeTruthy();
    expect(screen.getByText("Cash set aside")).toBeTruthy();
    expect(screen.getByRole("link", { name: /view in activity/i })).toBeTruthy();
  });
});
