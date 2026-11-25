import type { Candle, Interval, Order, Range } from "./api";

export interface Bar { time: number; open: number; high: number; low: number; close: number; volume: number | null }
export interface Pt { time: number; value: number }
export interface Fill { time: number; side: "buy" | "sell"; quantity: number; price: number }

export const RANGES: readonly Range[] = ["1D", "1W", "1M", "3M", "6M", "1Y", "5Y", "ALL"];
export const RANGE_LABEL: Record<Range, string> = { "1D": "1D", "1W": "1W", "1M": "1M", "3M": "3M", "6M": "6M", "1Y": "1Y", "5Y": "5Y", ALL: "All" };
/** CHT-02 / DAT-02: valid candle sizes per range, mirrored from the API (which answers 422 for anything else). */
export const VALID_INTERVALS: Record<Range, readonly ("1h" | "1d" | "1w")[]> = {
  "1D": ["1h"], "1W": ["1h", "1d"], "1M": ["1d"], "3M": ["1d", "1w"], "6M": ["1d", "1w"], "1Y": ["1d", "1w"], "5Y": ["1d", "1w"], ALL: ["1w"],
};
export const INTERVAL_LABEL: Record<string, string> = { "5m": "5m", "1h": "1h", "1d": "1D", "1w": "1W" };
export type ChartType = "line" | "area" | "candles";

/** Strictly ascending, unique times (lightweight-charts requirement); later duplicates win. */
export function toBars(candles: Candle[]): Bar[] {
  const m = new Map<number, Bar>();
  for (const c of candles) {
    m.set(c.time, { time: c.time, open: Number(c.open), high: Number(c.high), low: Number(c.low), close: Number(c.close), volume: c.volume === null || c.volume === undefined ? null : Number(c.volume) });
  }
  return [...m.values()].sort((a, b) => a.time - b.time);
}
export const pointsToBars = (pts: Pt[]): Bar[] => toBars(pts.map((p) => ({ time: p.time, open: String(p.value), high: String(p.value), low: String(p.value), close: String(p.value), volume: null })));

/** CHT-04: crypto series may carry no volume at all; then the toggle is hidden. */
export const hasVolume = (bars: Bar[]) => bars.some((b) => b.volume !== null && b.volume > 0);

/** CHT-05: simple moving average of the close. Empty when there are fewer candles than the period. */
export function sma(bars: Bar[], period: number): Pt[] {
  if (period < 1 || bars.length < period) return [];
  const out: Pt[] = [];
  let sum = 0;
  for (let i = 0; i < bars.length; i++) {
    sum += bars[i].close;
    if (i >= period) sum -= bars[i - period].close;
    if (i >= period - 1) out.push({ time: bars[i].time, value: sum / period });
  }
  return out;
}

/** CHT-07: rebase so the first point is 100. Returns [] when the first value is not positive. */
export function rebase(points: Pt[]): Pt[] {
  const base = points[0]?.value;
  if (!base || base <= 0) return [];
  return points.map((p) => ({ time: p.time, value: (p.value / base) * 100 }));
}

/** CHT-07: both series are rebased to 100 at the first visible close, i.e. the first primary bar's time.
 *  The compared series is cut to the primary's window first, so both start on the same footing. */
export function rebasePair(primary: Pt[], compare: Pt[]): { primary: Pt[]; compare: Pt[] } {
  if (!primary.length) return { primary: [], compare: [] };
  const from = primary[0].time, to = primary[primary.length - 1].time;
  const window = compare.filter((p) => p.time >= from && p.time <= to);
  return { primary: rebase(primary), compare: rebase(window) };
}
export const toPercentChange = (indexValue: number) => indexValue - 100;

/** CHT-10: "from open to now" for the selected range. */
export function rangeSummary(bars: Bar[]): { change: number; percent: number } | null {
  if (bars.length === 0) return null;
  const start = bars[0].open || bars[0].close, now = bars[bars.length - 1].close;
  return { change: now - start, percent: start ? ((now - start) / start) * 100 : 0 };
}

/** Index of the bar a timestamp falls into (latest bar whose time <= t), or null when t is before the data. */
export function snapToBar(times: number[], t: number): number | null {
  let lo = 0, hi = times.length - 1, ans: number | null = null;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (times[mid] <= t) { ans = mid; lo = mid + 1; } else hi = mid - 1;
  }
  return ans;
}

/** CHT-06: the user's filled orders for this asset as fills. Pending, cancelled and rejected orders are never marked. */
export function fillsFromOrders(orders: Order[]): Fill[] {
  return orders
    .filter((o) => o.status === "filled" && o.filled_at && o.quantity && o.price)
    .map((o) => ({ time: Math.floor(new Date(o.filled_at as string).getTime() / 1000), side: o.side, quantity: Number(o.quantity), price: Number(o.price) }));
}

/** Fills that fall inside the loaded window, grouped by the bar they snap to. */
export function fillsByBar(bars: Bar[], fills: Fill[], interval: Interval): Map<number, Fill[]> {
  const out = new Map<number, Fill[]>();
  if (bars.length === 0) return out;
  const times = bars.map((b) => b.time);
  const span = bars.length > 1 ? times[1] - times[0] : 3600;
  const tail = times[times.length - 1] + Math.max(span, SECONDS[interval] ?? span);
  for (const f of fills) {
    if (f.time < times[0] || f.time >= tail) continue; // outside what is on screen
    const i = snapToBar(times, f.time);
    if (i === null) continue;
    out.set(i, [...(out.get(i) ?? []), f]);
  }
  return out;
}
const SECONDS: Record<string, number> = { "5m": 300, "1h": 3600, "1d": 86400, "1w": 604800 };

const fmt2 = (n: number) => n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: n < 1 ? 6 : 2 });
export const fmtVolume = (n: number | null) => (n === null ? "–" : new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 }).format(n));

export function formatBarTitle(time: number, interval: Interval, range: Range): string {
  const d = new Date(time * 1000);
  const opts: Intl.DateTimeFormatOptions =
    interval === "5m" || interval === "1h" ? { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }
      : range === "5Y" || range === "ALL" || range === "1Y" ? { month: "short", day: "numeric", year: "numeric" } : { weekday: "short", month: "short", day: "numeric" };
  const text = new Intl.DateTimeFormat("en-US", opts).format(d);
  return interval === "1w" ? `Week of ${text}` : text;
}

export interface TipRow { label: string; value: string; tone?: "gain" | "loss" }
export interface Tip { title: string; rows: TipRow[]; change: { text: string; tone: "gain" | "loss" | "flat" } | null; trades: string[] }

/** CHT-08: what the tooltip card and the live region say about one candle (or one line point). */
export function describeBar(bars: Bar[], idx: number, o: { type: ChartType; interval: Interval; range: Range; fills?: Fill[]; percentAxis?: boolean; value?: (b: Bar) => number }): Tip | null {
  const b = bars[idx];
  if (!b) return null;
  const prev = idx > 0 ? bars[idx - 1] : null;
  const diff = prev ? b.close - prev.close : null;
  const pctChange = prev && prev.close ? ((b.close - prev.close) / prev.close) * 100 : null;
  const tone = b.close >= b.open ? "gain" : "loss";
  const rows: TipRow[] = o.type === "candles"
    ? [{ label: "Open", value: fmt2(b.open) }, { label: "High", value: fmt2(b.high) }, { label: "Low", value: fmt2(b.low) }, { label: "Close", value: fmt2(b.close), tone }]
    : [{ label: o.percentAxis ? "Change" : "Price", value: o.percentAxis && o.value ? signedPct(o.value(b) - 100) : fmt2(b.close) }];
  if (b.volume !== null) rows.push({ label: "Volume", value: fmtVolume(b.volume) });
  return {
    title: formatBarTitle(b.time, o.interval, o.range),
    rows,
    change: diff === null || pctChange === null ? null : { text: `${diff > 0 ? "▲" : diff < 0 ? "▼" : "•"} ${fmt2(Math.abs(diff))} (${Math.abs(pctChange).toFixed(2)}%) vs previous`, tone: diff > 0 ? "gain" : diff < 0 ? "loss" : "flat" },
    trades: (o.fills ?? []).map((f) => `${f.side === "buy" ? "Bought" : "Sold"} ${f.quantity.toLocaleString("en-US", { maximumFractionDigits: 8 })} at $${fmt2(f.price)}`),
  };
}
export const signedPct = (n: number) => `${n > 0 ? "+" : n < 0 ? "−" : ""}${Math.abs(n).toFixed(2)}%`;

/** Spoken version of a tooltip, for the visually hidden live region. */
export const tipToSpeech = (t: Tip) => [t.title, ...t.rows.map((r) => `${r.label} ${r.value}`), t.change?.text.replace(/^[▲▼•] /, (m) => (m.startsWith("▲") ? "Up " : m.startsWith("▼") ? "Down " : "")), ...t.trades].filter(Boolean).join(". ");

/** Time axis labels adapted to the range (CHT-09). `tickType` follows lightweight-charts: 0 year, 1 month, 2 day, 3 time. */
export function tickLabel(time: number, tickType: number, range: Range): string {
  const d = new Date(time * 1000);
  const f = (o: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat("en-US", o).format(d);
  if (tickType === 0) return f({ year: "numeric" });
  if (tickType === 1) return range === "5Y" || range === "ALL" || range === "1Y" ? f({ month: "short", year: "2-digit" }) : f({ month: "short" });
  if (tickType === 2) return f({ month: "short", day: "numeric" });
  return f({ hour: "numeric", minute: "2-digit" });
}

/** CHT-07: same rebasing for candles (OHLC all divided by the first close) so candles, averages and trades keep working while comparing. */
export function rebaseBars(bars: Bar[]): Bar[] {
  const base = bars[0]?.close;
  if (!base || base <= 0) return [];
  return bars.map((b) => ({ ...b, open: (b.open / base) * 100, high: (b.high / base) * 100, low: (b.low / base) * 100, close: (b.close / base) * 100 }));
}
export const barsToPoints = (bars: Bar[]): Pt[] => bars.map((b) => ({ time: b.time, value: b.close }));
