// Display-only formatting. Values come from the API as decimal strings.
const usd = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
const usdWhole = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });
export const money = (v: string | number) => usd.format(Number(v));
export const moneyWhole = (v: string | number) => usdWhole.format(Number(v));
export const price = (v: string | number) => {
  const n = Number(v);
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: n < 1 ? 6 : 2 }).format(n);
};
export const qty = (v: string) => new Intl.NumberFormat("en-US", { maximumFractionDigits: 8 }).format(Number(v));
export const signed = (v: string | number, fmt: (x: number) => string = (x) => money(x)) => {
  const n = Number(v);
  return `${n > 0 ? "+" : n < 0 ? "−" : ""}${fmt(Math.abs(n))}`;
};
export const pct = (v: string | number) => `${Number(v) > 0 ? "+" : Number(v) < 0 ? "−" : ""}${Math.abs(Number(v)).toFixed(2)}%`;
export const dir = (v: string | number): "up" | "down" | "flat" => (Number(v) > 0 ? "up" : Number(v) < 0 ? "down" : "flat");

const ET = "America/New_York";
export function formatOpen(iso: string, now = new Date()): string {
  const d = new Date(iso);
  const when = new Intl.DateTimeFormat("en-US", { timeZone: ET, weekday: "short", hour: "numeric", minute: "2-digit" }).format(d);
  const mins = Math.max(0, Math.round((d.getTime() - now.getTime()) / 60000));
  const left = mins >= 60 ? `${Math.floor(mins / 60)}h ${mins % 60}m` : `${mins}m`;
  return `Market opens ${when} ET (in ${left})`;
}
export const dateTime = (iso: string) =>
  new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(iso));
export const ageMinutes = (iso: string | null | undefined) => (iso ? (Date.now() - new Date(iso).getTime()) / 60000 : Infinity);
export function ago(iso: string) {
  const m = Math.round(ageMinutes(iso));
  return m < 60 ? `${m} min ago` : `${Math.round(m / 60)} h ago`;
}

/** Splits an amount into sign, whole dollars (with thousands separators) and two-digit cents, rounding half away from zero. */
export function splitMoney(v: string | number): { negative: boolean; whole: string; cents: string } {
  const n = Number(v);
  const cents = Math.round(Math.abs(n) * 100);
  const negative = n < 0 && cents > 0;
  return { negative, whole: new Intl.NumberFormat("en-US").format(Math.floor(cents / 100)), cents: String(cents % 100).padStart(2, "0") };
}

const compact = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });
/** 61,200,000 -> "61.2M"; missing values show an en dash so the row keeps its place. */
export const compactNumber = (v: string | number | null | undefined) => (v === null || v === undefined || v === "" ? "–" : compact.format(Number(v)));
export const dash = "–";
export const priceOrDash = (v: string | null | undefined) => (v === null || v === undefined ? dash : price(v));
/** "+19.2%" style for percentages that arrive as strings; arrow handled by <Delta>. */
export const absPct = (v: string | number) => `${Math.abs(Number(v)).toFixed(2)}%`;
