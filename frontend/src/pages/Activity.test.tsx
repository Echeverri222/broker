import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter } from "react-router-dom";
import Activity from "./Activity";

const cancelled: number[] = [];
const base = { symbol: "AAPL", name: "Apple", kind: "stock", side: "buy", realized_pnl: null, created_at: "2026-11-23T22:00:00Z", sell_all: false, requested_quantity: null, reserved_cash: "0.00" };
vi.mock("../lib/api", async (orig) => {
  const real = await orig<typeof import("../lib/api")>();
  return {
    ...real,
    api: {
      ...real.api,
      deposits: async () => ({ deposits: [] }),
      cancelOrder: async (id: number) => { cancelled.push(id); return {}; },
      orders: async () => ({ page: 1, per_page: 25, total: 3, orders: [
        { ...base, id: 3, status: "pending", quantity: null, price: null, total: null, filled_at: null, amount: "250.00", reserved_cash: "250.00", reject_reason: null },
        { ...base, id: 2, status: "rejected", quantity: null, price: null, total: null, filled_at: null, amount: "50.00", reject_reason: "Not enough cash." },
        { ...base, id: 1, status: "filled", quantity: "2.00000000", price: "100.00000000", total: "200.00", filled_at: "2026-11-23T20:00:00Z", amount: null, reject_reason: null },
      ] }),
    },
  };
});

describe("Activity statuses [QUE-01, QUE-07, QUE-08]", () => {
  it("labels waiting and rejected orders, explains why, and cancels a waiting one", async () => {
    render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}><MemoryRouter><Activity /></MemoryRouter></QueryClientProvider>);
    expect(await screen.findByText(/waiting for the market to open/i)).toBeTruthy();
    expect(screen.getByText("Not enough cash.")).toBeTruthy();
    await userEvent.click(screen.getByRole("button", { name: /cancel buy order for aapl/i }));
    expect(cancelled).toEqual([3]);
  });
});
