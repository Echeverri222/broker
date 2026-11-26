import type { components } from "./api-types";

// Types mirror PRD §6. All decimals arrive as strings; we only format them for display.
// Types that are new in v3 come straight from the generated OpenAPI types, so `check:api` guards them.
export type AssetListItem = components["schemas"]["AssetListItem"];
export type AssetListMeta = components["schemas"]["AssetListMeta"];
export type AssetStats = components["schemas"]["AssetStats"];
export interface AssetList { assets: AssetListItem[]; meta: AssetListMeta }
export interface MarketOverviewItem { symbol: string; label: string; price: string; change_percent: string | null; proxy_for: string | null }
export type Range = "1D" | "1W" | "1M" | "3M" | "6M" | "1Y" | "5Y" | "ALL";
export type Interval = "5m" | "1h" | "1d" | "1w";
export interface CandleSeries { symbol: string; range: Range; interval: Interval; candles: Candle[] }
export interface AssetQuery { q?: string; kind?: string; filter?: string; sector?: string; sort?: string; page?: number; limit?: number }

export type Kind = "stock" | "etf" | "crypto";
export interface Quote { price: string; previous_close: string | null; change: string; change_percent: string; as_of: string; fetched_at: string; stale: boolean }
export interface Asset { symbol: string; name: string; kind: Kind; sector: string | null; logo_url: string | null; quote: Quote | null }
export interface AssetDetail extends Asset { watched: boolean; stats: AssetStats; position: { quantity: string; average_cost: string; market_value: string | null } | null }
export interface Preferences { notify_order_filled: boolean; notify_order_rejected: boolean }
export interface User {
  id: number; name: string; email: string; account: { cash: string; reserved_cash: string; net_deposits: string };
  verified?: boolean; admin?: boolean; trading_enabled?: boolean; preferences?: Preferences;
}
export interface DeviceSession { id: number; user_agent: string | null; ip_address: string | null; created_at: string; last_seen_at: string; current: boolean }
export interface ServiceStatus { trading_enabled: boolean; market_open: boolean; providers: Record<string, "closed" | "half_open" | "open">; quotes_updated_seconds_ago: number | null; degraded: boolean }
export interface MarketStatus { open: boolean; next_open: string | null; next_close: string | null; session: "regular" | "closed"; early_close: boolean }
export interface Position { symbol: string; name: string; kind: Kind; quantity: string; average_cost: string; price: string | null; price_status: "ok" | "missing"; market_value: string | null; unrealized_pnl: string | null; unrealized_pnl_percent: string | null; day_change_percent: string; quote_as_of: string | null }
export interface Portfolio { cash: string; reserved_cash: string; net_deposits: string; total_value: string; invested_value: string; day_change: string; day_change_percent: string; total_return: string; total_return_percent: string; incomplete: boolean; positions: Position[] }
export interface SeriesPoint { time: string; value: string }
export interface Deposit { id: number; amount: string; kind: "initial" | "deposit"; created_at: string; cash?: string }
export interface History { range: string; deposits_in_range: string; series: SeriesPoint[]; return: string; return_percent: string; benchmark?: { symbol: string; series: SeriesPoint[] } | null; benchmark_error?: string; incomplete?: boolean }
export interface Candle { time: number; open: string; high: string; low: string; close: string; volume: string | null }
export interface Order { id: number; symbol: string; name: string; kind: Kind; side: "buy" | "sell"; quantity: string | null; price: string | null; total: string | null; realized_pnl: string | null; status: "pending" | "filled" | "cancelled" | "rejected"; filled_at: string | null; created_at: string; amount: string | null; requested_quantity: string | null; sell_all: boolean; reserved_cash: string; reject_reason: string | null }
export interface OrderResponse { order: Order; cash: string; reserved_cash: string; position: { symbol: string; quantity: string; average_cost: string } | null }
export interface OrderPage { orders: Order[]; page: number; per_page: number; total: number }

export class ApiError extends Error {
  constructor(public code: string, message: string, public status: number, public details: Record<string, string> = {}) { super(message); }
}

type Init = Omit<RequestInit, "headers"> & { json?: unknown; headers?: Record<string, string> };
async function request<T>(path: string, init: Init = {}): Promise<T> {
  const headers: Record<string, string> = { Accept: "application/json", ...init.headers };
  if (init.json !== undefined) { headers["Content-Type"] = "application/json"; init.body = JSON.stringify(init.json); }
  let res: Response;
  try { res = await fetch(`/api/v1${path}`, { ...init, headers, credentials: "same-origin" }); }
  catch { throw new ApiError("network", "Can't reach the server. Check your connection and try again.", 0); }
  if (res.status === 204) return undefined as T;
  const body = await res.json().catch(() => null);
  if (!res.ok) {
    const e = body?.error;
    throw new ApiError(e?.code ?? "unknown", e?.message ?? "Something went wrong. Please try again.", res.status, e?.details ?? {});
  }
  return body as T;
}

const qs = (o: Record<string, string | number | undefined>) => {
  const p = new URLSearchParams();
  Object.entries(o).forEach(([k, v]) => v !== undefined && v !== "" && p.set(k, String(v)));
  const s = p.toString();
  return s ? `?${s}` : "";
};

export const api = {
  signup: (b: { name: string; email: string; password: string }) => request<User>("/signup", { method: "POST", json: b }),
  login: (b: { email: string; password: string }) => request<User>("/session", { method: "POST", json: b }),
  logout: () => request<void>("/session", { method: "DELETE" }),
  me: () => request<User>("/me"),
  marketStatus: () => request<MarketStatus>("/market/status"),
  assets: (p: AssetQuery) => request<AssetList>(`/assets${qs(p as Record<string, string | number | undefined>)}`),
  marketOverview: () => request<{ items: MarketOverviewItem[] }>("/market/overview"),
  asset: (symbol: string) => request<AssetDetail>(`/assets/${encodeURIComponent(symbol)}`),
  candles: (symbol: string, range: Range, interval?: string) => request<CandleSeries>(`/assets/${encodeURIComponent(symbol)}/candles${qs({ range, interval })}`),
  portfolio: () => request<Portfolio>("/portfolio"),
  history: (range: string, benchmark: boolean) => request<History>(`/portfolio/history${qs({ range, benchmark: benchmark ? "SPY" : undefined })}`),
  orders: (p: { page?: number; side?: string; symbol?: string; status?: string; limit?: number }) => request<OrderPage>(`/orders${qs(p)}`),
  cancelOrder: (id: number) => request<{ order: Order; cash: string; reserved_cash: string }>(`/orders/${id}`, { method: "DELETE" }),
  placeOrder: (b: { symbol: string; side: "buy" | "sell"; amount?: string; quantity?: string; sell_all?: true }, key: string) =>
    request<OrderResponse>("/orders", { method: "POST", json: b, headers: { "Idempotency-Key": key } }),
  deposits: () => request<{ deposits: Deposit[] }>("/deposits"),
  deposit: (amount: string, key: string) => request<Deposit>("/deposits", { method: "POST", json: { amount }, headers: { "Idempotency-Key": key } }),
  watchlist: () => request<{ assets: Asset[] }>("/watchlist"),
  watch: (symbol: string) => request<Asset>("/watchlist", { method: "POST", json: { symbol } }),
  unwatch: (symbol: string) => request<void>(`/watchlist/${encodeURIComponent(symbol)}`, { method: "DELETE" }),
  reset: () => request<User>("/account/reset", { method: "POST", json: { confirm: "RESET" } }),
  // v4: sessions and account lifecycle
  sessions: () => request<{ sessions: DeviceSession[] }>("/sessions"),
  revokeSession: (id: number) => request<void>(`/sessions/${id}`, { method: "DELETE" }),
  revokeOtherSessions: () => request<void>("/sessions", { method: "DELETE" }),
  changePassword: (b: { current_password: string; password: string }) => request<void>("/account/password", { method: "PATCH", json: b }),
  preferences: (b: Partial<Preferences>) => request<User>("/account/preferences", { method: "PATCH", json: b }),
  exportData: () => request<Record<string, unknown>>("/account/export"),
  deleteAccount: (b: { confirm: "DELETE"; password: string }) => request<void>("/account", { method: "DELETE", json: b }),
  requestPasswordReset: (email: string) => request<void>("/password_reset", { method: "POST", json: { email } }),
  resetPassword: (b: { token: string; password: string }) => request<void>("/password_reset", { method: "PATCH", json: b }),
  verifyEmail: (token: string) => request<void>("/email_verification", { method: "PATCH", json: { token } }),
  resendVerification: () => request<void>("/email_verification", { method: "POST", json: {} }),
  status: () => request<ServiceStatus>("/status"),
};
