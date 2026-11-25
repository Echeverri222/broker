import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { axe } from "vitest-axe";
import type { AssetListItem } from "../lib/api";

vi.mock("../components/PriceChart", () => ({ PriceChart: ({ label, type }: { label: string; type: string }) => <div role="img" aria-label={label} data-type={type} /> }));

const calls: Record<string, unknown[]> = {};
const rec = (k: string, a: unknown) => { (calls[k] ??= []).push(a); };
const quote = { price: "100.00", previous_close: "98.00", change: "2.00", change_percent: "2.04", as_of: new Date().toISOString(), fetched_at: new Date().toISOString(), stale: false };
const item = (symbol: string, over: Partial<AssetListItem> = {}): AssetListItem => ({
  symbol, name: `${symbol} Inc.`, kind: "stock", sector: "Technology", logo_url: null, quote, watched: false, change_percent: "2.04", week52_position: "0.6000", spark: ["1", "2", "3"], volume: "1000", ...over,
});
let state = {
  total: 60, rows: [item("AAPL"), item("BTC", { kind: "crypto", sector: "Crypto", watched: true, change_percent: "-1.50" })], fuzzy: false,
  pending: [] as unknown[], positions: [] as unknown[], overview: [] as unknown[], filled: [] as unknown[], watchlist: [] as unknown[], open: false,
  stats: { open: null, day_low: null, day_high: null, week52_low: null, week52_high: null, volume: null, avg_volume: null, change_1m_percent: null, change_1y_percent: null } as Record<string, string | null>,
  candles: [] as unknown[], position: null as unknown,
};
const portfolio = () => ({ cash: "1000.00", reserved_cash: "0.00", net_deposits: "1000.00", total_value: "1000.00", invested_value: "0.00", day_change: "0.00", day_change_percent: "0.00", total_return: "0.00", total_return_percent: "0.00", incomplete: false, positions: state.positions });

vi.mock("../lib/api", async (orig) => {
  const real = await orig<typeof import("../lib/api")>();
  return { ...real, api: { ...real.api,
    me: async () => ({ id: 7, name: "Ada", email: "ada@example.test", account: { cash: "1000.00", reserved_cash: "0.00", net_deposits: "1000.00" } }),
    portfolio: async () => portfolio(),
    marketStatus: async () => ({ open: state.open, next_open: "2026-11-24T14:30:00Z", next_close: "2026-11-24T21:00:00Z", session: "closed", early_close: false }),
    marketOverview: async () => ({ items: state.overview }),
    history: async () => ({ range: "1M", deposits_in_range: "0.00", series: [], return: "0.00", return_percent: "0.00", benchmark: null }),
    watchlist: async () => ({ assets: state.watchlist }),
    orders: async (p: { status?: string }) => { rec("orders", p); return { page: 1, per_page: 50, total: 0, orders: p.status === "pending" ? state.pending : state.filled }; },
    assets: async (p: Record<string, unknown>) => { rec("assets", p); return { assets: state.rows, meta: { total: state.total, page: Number(p.page ?? 1), limit: 25, fuzzy: state.fuzzy, counts: { all: 54, stock: 32, etf: 8, crypto: 14, watching: 1, owned: 0 }, sectors: ["Technology", "Crypto"] } }; },
    asset: async (s: string) => ({ symbol: s, name: "Apple Inc.", kind: "stock", sector: "Technology", logo_url: null, watched: false, quote, stats: state.stats, position: state.position }),
    candles: async () => ({ symbol: "AAPL", range: "1M", interval: "1d", candles: state.candles }),
    watch: async () => ({}), unwatch: async () => undefined,
  } };
});

import Markets from "./Markets";
import Dashboard, { greeting } from "./Dashboard";
import AssetPage from "./AssetPage";
import Welcome from "./Welcome";
import Settings from "./Settings";

const Where = () => { const l = useLocation(); return <output data-testid="where">{l.pathname}{l.search}</output>; };
function renderAt(path: string, el: React.ReactElement, route = path.split("?")[0].replace(/\/AAPL$/, "/:symbol")) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[path]}><Routes><Route path={route} element={el} /><Route path="*" element={null} /></Routes><Where /></MemoryRouter>
    </QueryClientProvider>,
  );
}
const where = () => screen.getByTestId("where").textContent;
const reset = () => {
  Object.keys(calls).forEach((k) => delete calls[k]);
  state = { ...state, total: 60, rows: [item("AAPL"), item("BTC", { kind: "crypto", sector: "Crypto", watched: true, change_percent: "-1.50" })], fuzzy: false, pending: [], positions: [], overview: [], filled: [], watchlist: [], open: false, candles: [], position: null,
    stats: { open: null, day_low: null, day_high: null, week52_low: null, week52_high: null, volume: null, avg_volume: null, change_1m_percent: null, change_1y_percent: null } };
};

describe("Markets filters [FLT-01..10, QA-02]", () => {
  beforeEach(reset);

  it("shows the Show chips with API counts, the quick picks, sort and sector controls [FLT-02, FLT-03, FLT-04, FLT-05]", async () => {
    renderAt("/markets", <Markets />);
    const show = await screen.findByRole("radiogroup", { name: "Show" });
    for (const l of ["All", "Stocks", "Crypto", "ETFs", "Watching", "You own"]) expect(within(show).getByRole("radio", { name: new RegExp(`^${l}`) })).toBeTruthy();
    await waitFor(() => expect(within(show).getByRole("radio", { name: /^Stocks/ }).textContent).toContain("32"));
    const picks = screen.getByRole("group", { name: "Quick picks" });
    for (const l of ["Top gainers", "Top losers", "Most traded", "Near 52-week high", "Under $50", "Open now"]) expect(within(picks).getByRole("button", { name: l })).toBeTruthy();
    expect(screen.getByLabelText("Sort")).toBeTruthy();
    expect(screen.getByLabelText("Sector")).toBeTruthy();
  });

  it("writes every filter into the URL and reads it back [FLT-08]", async () => {
    const user = userEvent.setup();
    renderAt("/markets", <Markets />);
    await user.click(await screen.findByRole("radio", { name: /^Crypto/ }));
    await user.click(screen.getByRole("button", { name: "Top gainers" }));
    await user.click(screen.getByRole("button", { name: "Under $50" }));
    await user.selectOptions(screen.getByLabelText("Sort"), "price_asc");
    await user.selectOptions(screen.getByLabelText("Sector"), "Crypto");
    expect(where()).toBe("/markets?show=crypto&pick=gainers%2Cunder_50&sort=price_asc&sector=Crypto");
    await waitFor(() => expect(calls.assets.at(-1)).toMatchObject({ kind: "crypto", filter: "gainers,under_50", sort: "price_asc", sector: "Crypto" }));
  });

  it("restores the view from a shared URL [FLT-08]", async () => {
    renderAt("/markets?show=watching&pick=losers&sort=name&q=app", <Markets />);
    expect((await screen.findByRole("radio", { name: /^Watching/ })).getAttribute("aria-checked")).toBe("true");
    expect(screen.getByRole("button", { name: "Top losers" }).getAttribute("aria-pressed")).toBe("true");
    expect((screen.getByLabelText("Sort") as HTMLSelectElement).value).toBe("name");
    expect((screen.getByLabelText("Search assets") as HTMLInputElement).value).toBe("app");
    await waitFor(() => expect(calls.assets.at(-1)).toMatchObject({ q: "app", filter: "watching,losers", sort: "name" }));
  });

  it("debounces search into ?q= and Esc clears it; / focuses it [FLT-01, FLT-10]", async () => {
    const user = userEvent.setup();
    renderAt("/markets", <Markets />);
    const box = await screen.findByLabelText("Search assets");
    await user.keyboard("/");
    expect(document.activeElement).toBe(box);
    await user.type(box, "bit");
    await waitFor(() => expect(where()).toContain("q=bit"));
    await user.keyboard("{Escape}");
    await waitFor(() => expect(where()).not.toContain("q="));
  });

  it("paginates with Show more and says how many are shown [FLT-07]", async () => {
    const user = userEvent.setup();
    renderAt("/markets", <Markets />);
    expect(await screen.findByText(/showing 2 of 60/i)).toBeTruthy();
    await user.click(screen.getByRole("button", { name: /show more/i }));
    await waitFor(() => expect(calls.assets.at(-1)).toMatchObject({ page: 2, limit: 25 }));
  });

  it("renders the columns, the in-place watch star and a sparkline per row [FLT-06]", async () => {
    renderAt("/markets", <Markets />);
    expect(await screen.findByText("52-week range")).toBeTruthy();
    expect(screen.getByText("Last month")).toBeTruthy();
    expect(screen.getByRole("button", { name: "Watch AAPL" }).getAttribute("aria-pressed")).toBe("false");
    expect(screen.getByRole("button", { name: "Stop watching BTC" }).getAttribute("aria-pressed")).toBe("true");
    expect(screen.getAllByTestId("sparkline").length).toBeGreaterThan(0);
  });

  it("shows the empty state with Clear filters, and the fuzzy note [FLT-09]", async () => {
    state.rows = []; state.total = 0;
    const user = userEvent.setup();
    renderAt("/markets?pick=gainers", <Markets />);
    expect(await screen.findByText("Nothing matches. Try fewer filters.")).toBeTruthy();
    await user.click(screen.getAllByRole("button", { name: "Clear filters" })[0]);
    await waitFor(() => expect(where()).toBe("/markets"));
  });
  it("labels near-miss results [FLT-09]", async () => {
    state.fuzzy = true;
    renderAt("/markets?q=aple", <Markets />);
    expect(await screen.findByText(/showing results for/i)).toBeTruthy();
  });
});

describe("Home [HOME-01..08, QA-02]", () => {
  beforeEach(reset);

  it("greets by the hour with a muted status clause and the four pills [HOME-01, HOME-02]", async () => {
    expect([greeting(8), greeting(13), greeting(20)]).toEqual(["Good morning", "Good afternoon", "Good evening"]);
    renderAt("/", <Dashboard />);
    await waitFor(() => expect(screen.getByRole("heading", { level: 1 }).textContent).toMatch(/Ada\. Markets open Tuesday at 9:30\./));
    const pills = screen.getByRole("group", { name: "Quick actions" });
    expect(within(pills).getAllByRole("button").map((b) => b.textContent)).toEqual(["Buy", "Sell", "Add cash", "Watch"]);
  });

  it("opens the symbol picker from Buy and goes to the trade [HOME-02]", async () => {
    state.rows = [item("AAPL")];
    const user = userEvent.setup();
    renderAt("/", <Dashboard />);
    await user.click(await screen.findByRole("button", { name: "Buy" }));
    await user.click(await screen.findByRole("button", { name: /AAPL/ }));
    await waitFor(() => expect(where()).toBe("/assets/AAPL?trade=buy"));
  });

  it("hides the markets strip when there are no quotes and shows it with a proxy tooltip otherwise [HOME-03]", async () => {
    const { unmount } = renderAt("/", <Dashboard />);
    await screen.findByRole("heading", { level: 1 });
    expect(screen.queryByRole("list", { name: "Markets today" })).toBeNull();
    unmount();
    state.overview = [{ symbol: "SPY", label: "S&P 500", price: "722.29", change_percent: "1.20", proxy_for: "SPY" }];
    renderAt("/", <Dashboard />);
    const strip = await screen.findByRole("list", { name: "Markets today" });
    expect(within(strip).getByText("S&P 500").closest("li")!.getAttribute("title")).toBe("Tracked with the SPY fund");
  });

  it("has range tabs 1D..1Y and a Line/Area switch on the shared chart; no candles [HOME-04, CHT-12]", async () => {
    renderAt("/", <Dashboard />);
    const tabs = await screen.findByRole("tablist", { name: "Range" });
    expect(within(tabs).getAllByRole("tab").map((t) => t.textContent)).toEqual(["1D", "1W", "1M", "3M", "1Y"]);
    expect(within(screen.getByRole("tablist", { name: "Chart type" })).getAllByRole("tab").map((t) => t.textContent)).toEqual(["Line", "Area"]);
  });

  it("splits accounts into cash, set aside and invested with a 3-segment bar [HOME-05]", async () => {
    renderAt("/", <Dashboard />);
    const card = (await screen.findByRole("heading", { name: "Accounts" })).closest("section")!;
    for (const t of ["Cash to spend", "Set aside for orders", "Invested"]) expect(within(card).getByText(t)).toBeTruthy();
    expect(within(card).getByRole("img").getAttribute("aria-label")).toMatch(/cash 100%/i);
    expect(within(card).getByRole("link", { name: /open activity/i })).toBeTruthy();
  });

  it("shows the amber waiting-orders card only when orders are pending [HOME-06]", async () => {
    const { unmount } = renderAt("/", <Dashboard />);
    await screen.findByRole("heading", { level: 1 });
    expect(screen.queryByText(/order waiting/i)).toBeNull();
    unmount();
    state.pending = [{ id: 4, symbol: "AAPL", side: "buy", amount: "250.00", sell_all: false, requested_quantity: null }];
    renderAt("/", <Dashboard />);
    expect(await screen.findByText("1 order waiting")).toBeTruthy();
    expect(screen.getByRole("button", { name: /cancel buy order for aapl/i })).toBeTruthy();
  });

  it("lists holdings with a sparkline, or one sentence and a Buy button when empty [HOME-07]", async () => {
    const { unmount } = renderAt("/", <Dashboard />);
    expect(await screen.findByText(/you don't own anything yet/i)).toBeTruthy();
    expect(screen.queryByRole("table")).toBeNull();
    unmount();
    state.positions = [{ symbol: "AAPL", name: "Apple Inc.", kind: "stock", quantity: "2", average_cost: "90", price: "100", price_status: "ok", market_value: "200.00", unrealized_pnl: "20", unrealized_pnl_percent: "11", day_change_percent: "2.04", quote_as_of: null }];
    renderAt("/", <Dashboard />);
    const row = (await screen.findByText("Apple Inc.")).closest("a")!;
    expect(row.getAttribute("href")).toBe("/assets/AAPL");
    await waitFor(() => expect(within(row).getByTestId("sparkline")).toBeTruthy());
  });

  it("derives first-run checklist progress from real data and can be dismissed per user [HOME-08]", async () => {
    try { localStorage.clear(); } catch { /* ignore */ }
    state.filled = [{ id: 1, side: "buy", status: "filled" }];
    state.watchlist = [];
    const user = userEvent.setup();
    renderAt("/", <Dashboard />);
    const card = (await screen.findByRole("heading", { name: /get started/i })).closest("section")!;
    expect(card.textContent).toContain("2 of 4");
    expect(within(card).getByText("Make your first buy").parentElement!.textContent).toContain("(done)");
    expect(within(card).getByText("Watch something").parentElement!.textContent).toContain("(not done yet)");
    await user.click(within(card).getByRole("button", { name: /dismiss checklist/i }));
    expect(screen.queryByRole("heading", { name: /get started/i })).toBeNull();
    expect(localStorage.getItem("pb_checklist_dismissed:7")).toBe("1");
  });
  it("hides the checklist once every step is done [HOME-08]", async () => {
    try { localStorage.clear(); } catch { /* ignore */ }
    state.filled = [{ id: 1, side: "buy", status: "filled" }, { id: 2, side: "sell", status: "filled" }];
    state.watchlist = [item("AAPL")];
    renderAt("/", <Dashboard />);
    await screen.findByRole("heading", { level: 1 });
    await new Promise((r) => setTimeout(r, 50));
    expect(screen.queryByRole("heading", { name: /get started/i })).toBeNull();
  });
});

describe("Asset page [CHT-01, CHT-02, CHT-11, CHT-14, CHT-15, QA-02]", () => {
  beforeEach(reset);
  const candle = (i: number) => ({ time: 1_700_000_000 + i * 86400, open: "100", high: "101", low: "99", close: "100.5", volume: "1000" });

  it("shows toolbars, the chart type switch and the Candles-only size selector [CHT-01, CHT-02]", async () => {
    state.candles = [candle(0), candle(1), candle(2)];
    const user = userEvent.setup();
    renderAt("/assets/AAPL", <AssetPage />);
    expect(await screen.findByRole("tablist", { name: "Range" })).toBeTruthy();
    expect(screen.queryByRole("tablist", { name: "Candle size" })).toBeNull();
    await user.click(screen.getByRole("tab", { name: "Candles" }));
    expect(screen.getByRole("tablist", { name: "Candle size" })).toBeTruthy();
    expect(localStorage.getItem("pb_chart_type:7")).toBe("candles");
    expect(await screen.findByRole("img", { name: /aapl price chart, 1M/i })).toBeTruthy();
  });

  it("shows the key numbers card, with a dash for anything missing [CHT-11]", async () => {
    state.stats = { ...state.stats, open: "99.00", volume: "61200000", avg_volume: "50000000" };
    renderAt("/assets/AAPL", <AssetPage />);
    const card = (await screen.findByRole("heading", { name: "Key numbers" })).closest("section")!;
    for (const t of ["Open", "Yesterday's close", "Volume", "Average volume", "1 month change", "1 year change", "Today's range", "52-week range"]) expect(within(card).getByText(t)).toBeTruthy();
    expect(within(card).getByText("61.2M")).toBeTruthy();
    expect(within(card).getAllByText("–").length).toBeGreaterThanOrEqual(2);
  });

  it("shows the empty chart state [CHT-14]", async () => {
    renderAt("/assets/AAPL", <AssetPage />);
    expect(await screen.findByText("No price history for this range")).toBeTruthy();
  });

  it("puts the trade panel in the right column with a single primary action and chips [CHT-15]", async () => {
    renderAt("/assets/AAPL", <AssetPage />);
    const panel = await screen.findByRole("region", { name: "Trade AAPL" });
    expect(within(panel).getByRole("button", { name: "Queue buy for Tuesday" })).toBeTruthy();
    for (const c of ["$100", "$500", "$1,000", "All cash"]) expect(within(panel).getByRole("button", { name: c })).toBeTruthy();
    expect(within(panel).getByText("You'll get about")).toBeTruthy();
  });
});

describe("Welcome and Settings [WEL-01, WEL-02, QA-02]", () => {
  it("has the two-line headline, the form with the password hint, and a static example card [WEL-01]", () => {
    renderAt("/welcome", <Welcome />);
    expect(screen.getByRole("heading", { level: 1 }).textContent).toMatch(/\$100,000 of virtual cash/);
    expect(screen.getByLabelText(/name/i)).toBeTruthy();
    expect(screen.getByText("At least 8 characters.")).toBeTruthy();
    expect(screen.getByRole("button", { name: "Create account" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Sign in" })).toBeTruthy();
    expect(screen.getByRole("region", { name: /example portfolio, for illustration only/i })).toBeTruthy();
  });

  it("offers Light, Dark and Match device and applies them [WEL-02, DSN-02]", async () => {
    const user = userEvent.setup();
    renderAt("/settings", <Settings />);
    const group = await screen.findByRole("radiogroup", { name: "Appearance" });
    expect(within(group).getAllByRole("radio").map((r) => r.textContent)).toEqual(["Light", "Dark", "Match device"]);
    await user.click(within(group).getByRole("radio", { name: "Dark" }));
    expect(document.documentElement.dataset.theme).toBe("dark");
    expect(screen.getByRole("button", { name: /reset account/i })).toBeTruthy();
    expect(screen.getByRole("button", { name: /sign out/i })).toBeTruthy();
  });
});

describe("accessibility in both themes [QA-02, DSN-05, DSN-10]", () => {
  beforeEach(reset);
  const pages: [string, string, React.ReactElement, string?][] = [
    ["Home", "/", <Dashboard />], ["Asset", "/assets/AAPL", <AssetPage />], ["Markets", "/markets", <Markets />], ["Welcome", "/welcome", <Welcome />],
  ];
  for (const theme of ["light", "dark"] as const) {
    for (const [name, path, el] of pages) {
      it(`${name} has no axe violations in ${theme}`, async () => {
        document.documentElement.dataset.theme = theme;
        state.candles = [candle(), candle()];
        state.pending = name === "Home" ? [{ id: 4, symbol: "AAPL", side: "buy", amount: "250.00", sell_all: false, requested_quantity: null }] : [];
        state.overview = name === "Home" ? [{ symbol: "SPY", label: "S&P 500", price: "722.29", change_percent: "1.20", proxy_for: "SPY" }] : [];
        const { container } = renderAt(path, el);
        await screen.findAllByRole(name === "Welcome" ? "button" : "heading");
        await new Promise((r) => setTimeout(r, 80));
        const res = await axe(container, { rules: { "color-contrast": { enabled: false }, region: { enabled: false } } });
        expect(res.violations.map((v) => `${v.id}: ${v.nodes[0]?.html}`)).toEqual([]);
      });
    }
  }
  function candle() { return { time: 1_700_000_000, open: "100", high: "101", low: "99", close: "100.5", volume: "1000" }; }
});
