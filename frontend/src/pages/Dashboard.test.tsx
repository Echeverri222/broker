import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter } from "react-router-dom";
import Dashboard from "./Dashboard";

let mode: "error" | "empty" = "error";
vi.mock("../lib/api", async (orig) => {
  const real = await orig<typeof import("../lib/api")>();
  const never = () => new Promise(() => {});
  return {
    ...real,
    api: {
      ...real.api,
      portfolio: async () => {
        if (mode === "error") throw new Error("boom");
        return { cash: "100.00", net_deposits: "100.00", total_value: "100.00", invested_value: "0.00", day_change: "0.00", day_change_percent: "0.00", total_return: "0.00", total_return_percent: "0.00", incomplete: false, positions: [] };
      },
      history: never,
      watchlist: never,
    },
  };
});

const renderIt = () => render(
  <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
    <MemoryRouter><Dashboard /></MemoryRouter>
  </QueryClientProvider>,
);

describe("Dashboard states [UX-09]", () => {
  it("shows an error with retry when the portfolio fails", async () => {
    mode = "error";
    renderIt();
    expect(await screen.findByText(/couldn't load your portfolio/i)).toBeTruthy();
    expect(screen.getByRole("button", { name: /retry|try again/i })).toBeTruthy();
  });

  it("shows an empty state with a call to action when nothing is held", async () => {
    mode = "empty";
    renderIt();
    expect(await screen.findByText(/you don't own anything yet/i)).toBeTruthy();
  });
});
