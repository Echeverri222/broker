import { useMemo, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, X } from "lucide-react";
import { api, type MarketOverviewItem, type Portfolio } from "../lib/api";
import { dash, money, qty } from "../lib/format";
import { pollInterval, useMarket, useMarketOverview, useMe, usePortfolio } from "../lib/query";
import { Button, Card, CardTitle, CornerLink, Delta, Empty, ErrorBox, HIT, Logo, Segmented, Skeleton, Sparkline, pillClass } from "../components/ui";
import { Money } from "../components/Money";
import { PriceChart } from "../components/PriceChart";
import { SymbolPicker } from "../components/SymbolPicker";
import { DepositSheet } from "../components/DepositSheet";
import { pointsToBars, type ChartType } from "../lib/chart";

const RANGES = ["1D", "1W", "1M", "3M", "1Y"] as const;
type HomeRange = (typeof RANGES)[number];

/** HOME-01: greeting by local hour. */
export const greeting = (hour: number) => (hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening");
const weekday = (iso: string) => new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", weekday: "long" }).format(new Date(iso));
const clock = (iso: string) => new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", hour: "numeric", minute: "2-digit" }).format(new Date(iso));

function Headline({ name }: { name: string }) {
  const market = useMarket().data;
  const status = !market ? "" : market.open && market.next_close ? `Markets close at ${clock(market.next_close)}.` : market.next_open ? `Markets open ${weekday(market.next_open)} at ${clock(market.next_open).replace(/ ?(AM|PM)$/, "")}.` : "Markets are closed.";
  return (
    <h1 className="m-0 text-[32px] font-semibold leading-[1.15] tracking-[-0.025em] md:text-[40px]">
      {greeting(new Date().getHours())}, {name}. <span className="font-medium text-mute">{status}</span>
    </h1>
  );
}

/** HOME-03: hidden entirely when the server has no quotes for these. */
function MarketsStrip() {
  const { data } = useMarketOverview();
  const items = data?.items ?? [];
  if (items.length === 0) return null;
  return (
    <ul aria-label="Markets today" className="flex flex-wrap gap-3">
      {items.map((m: MarketOverviewItem) => (
        <li key={m.symbol} title={m.proxy_for ? `Tracked with the ${m.proxy_for} fund` : undefined}
          className="flex min-h-11 items-center gap-3 rounded-full border border-line bg-card px-4 text-sm">
          <span className="font-semibold">{m.label}</span>
          <span className="num rounded-full bg-well px-2.5 py-0.5 font-semibold">{Number(m.price).toLocaleString("en-US", { maximumFractionDigits: 2 })}</span>
          {m.change_percent !== null && <Delta percent={m.change_percent} className="text-[13px]" />}
        </li>
      ))}
    </ul>
  );
}

const toPts = (s?: { time: string; value: string }[] | null) => s?.map((p) => ({ time: Math.floor(new Date(p.time).getTime() / 1000), value: Number(p.value) })) ?? [];

function PortfolioCard({ p }: { p: Portfolio }) {
  const [range, setRange] = useState<HomeRange>("1M");
  const [type, setType] = useState<ChartType>("line");
  const hist = useQuery({ queryKey: ["history", range, true], queryFn: () => api.history(range, true), refetchInterval: () => pollInterval() });
  const bars = useMemo(() => pointsToBars(toPts(hist.data?.series)), [hist.data]);
  const bench = useMemo(() => toPts(hist.data?.benchmark?.series), [hist.data]);
  const h = hist.data;
  // HOME-04: only when benchmark data exists. Compares percentage moves over the range.
  const lead = (() => {
    if (!h || bench.length < 2 || !Number(bench[0].value)) return null;
    const b = (bench[bench.length - 1].value / bench[0].value - 1) * 100, diff = Number(h.return_percent) - b;
    return Math.abs(diff) < 0.05 ? "In line with the market" : `${Math.abs(diff).toFixed(1)}% ${diff > 0 ? "ahead of" : "behind"} the market`;
  })();
  return (
    <Card aria-labelledby="portfolio-title">
      <div className="flex items-start justify-between gap-3">
        <CardTitle id="portfolio-title" muted="practice money">Your portfolio</CardTitle>
        <CornerLink to="/activity" label="Open activity" />
      </div>
      <p className="mt-4 text-[44px] font-semibold leading-none tracking-[-0.03em] md:text-[56px]"><Money value={p.total_value} /></p>
      <div className="mt-3 flex flex-wrap gap-x-6 gap-y-1 text-sm">
        <span><span className="text-mute" title="Change since the previous market close">Today </span><Delta value={p.day_change} percent={p.day_change_percent} /></span>
        <span><span className="text-mute" title="Gain or loss compared with what you put in. Cash you add is not counted as profit.">All time </span><Delta value={p.total_return} percent={p.total_return_percent} /></span>
      </div>
      {p.incomplete && <p role="status" className="mt-3 rounded-xl border border-line bg-well p-3 text-sm">Some prices are unavailable right now, so the total excludes those positions.</p>}
      <div className="mt-5 flex flex-wrap items-center justify-between gap-3">
        <Segmented label="Range" options={RANGES.map((r) => ({ value: r, label: r }))} value={range} onChange={setRange} />
        <Segmented label="Chart type" options={[{ value: "line", label: "Line" }, { value: "area", label: "Area" }]} value={type} onChange={(t) => setType(t as ChartType)} />
      </div>
      <div className="mt-4">
        {hist.isLoading ? <Skeleton className="h-[280px] w-full" /> : hist.isError ? <ErrorBox message="Couldn't load performance." onRetry={() => hist.refetch()} />
          : bars.length === 0 ? <p className="grid h-[280px] place-items-center text-sm text-mute">No history yet. It builds up as prices are recorded.</p>
          : <PriceChart bars={bars} type={type} range={range} interval="1d" height={280} label={`Portfolio value, ${range}`} compare={bench.length ? { label: "S&P 500", points: bench, mode: "overlay" } : null} />}
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-x-5 gap-y-1 text-xs text-mute">
        <span className="inline-flex items-center gap-2"><i aria-hidden className="inline-block h-0.5 w-5 bg-[var(--chart)]" />Your portfolio</span>
        {bench.length > 0 && <span className="inline-flex items-center gap-2"><i aria-hidden className="inline-block w-5 border-t-2 border-dashed border-[var(--bench)]" />S&amp;P 500</span>}
        {lead && <span className="font-semibold text-ink">{lead}</span>}
        {h && Number(h.deposits_in_range) > 0 && <span>Excludes {money(h.deposits_in_range)} you added in this period</span>}
        {h?.benchmark_error && <span>{h.benchmark_error}</span>}
      </div>
    </Card>
  );
}

function AccountsCard({ p }: { p: Portfolio }) {
  const reserved = Number(p.reserved_cash), cash = Math.max(0, Number(p.cash) - reserved), invested = Number(p.invested_value);
  const total = cash + reserved + invested || 1;
  const rows: [string, number, string][] = [["Cash to spend", cash, "var(--bar)"], ["Set aside for orders", reserved, "var(--amber)"], ["Invested", invested, "var(--chart)"]];
  return (
    <Card aria-labelledby="accounts-title">
      <div className="flex items-start justify-between"><CardTitle id="accounts-title">Accounts</CardTitle><CornerLink to="/activity" label="Open activity" /></div>
      <div role="img" aria-label={`Cash ${Math.round((cash / total) * 100)}%, set aside ${Math.round((reserved / total) * 100)}%, invested ${Math.round((invested / total) * 100)}%`} className="mt-4 flex h-2.5 gap-0.5 overflow-hidden rounded-full bg-well">
        {rows.map(([k, v, c]) => v > 0 && <span key={k} style={{ width: `${(v / total) * 100}%`, background: c }} />)}
      </div>
      <dl className="mt-4 space-y-3 text-sm">
        {rows.map(([k, v, c]) => (
          <div key={k} className="flex items-center justify-between"><dt className="flex items-center gap-2 text-mute"><i aria-hidden className="inline-block size-2.5 rounded-full" style={{ background: c }} />{k}</dt><dd className="font-semibold"><Money value={v} /></dd></div>
        ))}
      </dl>
    </Card>
  );
}

/** HOME-06: amber card, only while orders are waiting for the market to open. */
function WaitingOrders() {
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ["orders", "pending"], queryFn: () => api.orders({ status: "pending", limit: 50 }), refetchInterval: () => pollInterval() });
  const cancel = useMutation({ mutationFn: (id: number) => api.cancelOrder(id), onSuccess: () => { ["orders", "portfolio", "me"].forEach((k) => void qc.invalidateQueries({ queryKey: [k] })); } });
  const list = q.data?.orders ?? [];
  if (list.length === 0) return null;
  const o = list[0];
  const what = o.sell_all ? `all of ${o.symbol}` : o.amount ? `${money(o.amount)} of ${o.symbol}` : `${qty(o.requested_quantity ?? "0")} ${o.symbol}`;
  return (
    <section aria-labelledby="waiting-title" className="rounded-[24px] border border-[var(--amber)] bg-amber-bg p-5 text-amber-ink">
      <h2 id="waiting-title" className="m-0 text-[18px] font-semibold">{list.length === 1 ? "1 order waiting" : `${list.length} orders waiting`}</h2>
      <p className="mt-1 text-sm">{o.side === "buy" ? "Buy" : "Sell"} {what}{list.length > 1 ? ` and ${list.length - 1} more` : ""}. Placed when the market opens.</p>
      <Button variant="secondary" className="mt-3 border-[var(--amber)] bg-transparent text-amber-ink" disabled={cancel.isPending} aria-label={`Cancel ${o.side} order for ${o.symbol}`} onClick={() => cancel.mutate(o.id)}>Cancel</Button>
    </section>
  );
}

function Holdings({ p, onBuy }: { p: Portfolio; onBuy: () => void }) {
  const owned = useQuery({ queryKey: ["assets", "owned-spark"], queryFn: () => api.assets({ filter: "owned", limit: 50 }), enabled: p.positions.length > 0, staleTime: 60_000 });
  const spark = new Map(owned.data?.assets.map((a) => [a.symbol, a]));
  return (
    <Card aria-labelledby="holdings-title">
      <div className="flex items-start justify-between"><CardTitle id="holdings-title">Holdings</CardTitle><CornerLink to="/markets?show=owned" label="Open holdings in Markets" /></div>
      {p.positions.length === 0 ? (
        <Empty title="You don't own anything yet." body="Buy your first asset with practice money to see it here." action={<Button className="mt-3" onClick={onBuy}>Buy</Button>} />
      ) : (
        <ul className="mt-2 divide-y divide-line">
          {p.positions.map((pos) => {
            const s = spark.get(pos.symbol);
            return (
              <li key={pos.symbol} className="lift">
                <Link to={`/assets/${pos.symbol}`} className="flex min-h-[68px] items-center gap-3 py-2">
                  <Logo symbol={pos.symbol} logoUrl={s?.logo_url} size={44} />
                  <div className="min-w-0 flex-1"><p className="truncate font-semibold">{pos.name}</p><p className="truncate text-xs text-mute">{qty(pos.quantity)} {pos.symbol}</p></div>
                  <Sparkline data={s?.spark} width={84} height={28} />
                  <div className="w-[104px] text-right">
                    <p className="font-semibold">{pos.market_value ? <Money value={pos.market_value} /> : "Price unavailable"}</p>
                    {pos.market_value && <Delta percent={pos.day_change_percent} className="text-xs" />}
                  </div>
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </Card>
  );
}

/** HOME-08: progress comes from real data; dismissal is per user and stored locally. */
const dismissKey = (id?: number) => `pb_checklist_dismissed:${id ?? "anon"}`;
export function Checklist({ userId }: { userId?: number }) {
  const [dismissed, setDismissed] = useState(() => { try { return localStorage.getItem(dismissKey(userId)) === "1"; } catch { return false; } });
  const orders = useQuery({ queryKey: ["orders", "checklist"], queryFn: () => api.orders({ status: "filled", limit: 200 }), staleTime: 15_000 });
  const watch = useQuery({ queryKey: ["watchlist"], queryFn: api.watchlist, refetchInterval: () => pollInterval() });
  if (dismissed || !orders.data || !watch.data) return null;
  const list = orders.data.orders;
  const steps: [string, boolean, string][] = [
    ["Create your account", true, "Done. You start with practice money."],
    ["Make your first buy", list.some((o) => o.side === "buy"), "Pick any asset and buy a small amount."],
    ["Watch something", watch.data.assets.length > 0, "Tap Watch on an asset to follow it."],
    ["Sell and see your profit", list.some((o) => o.side === "sell"), "Sell part of a holding to see what you made."],
  ];
  if (steps.every((s) => s[1])) return null;
  const done = steps.filter((s) => s[1]).length;
  return (
    <Card aria-labelledby="checklist-title">
      <div className="flex items-start justify-between">
        <CardTitle id="checklist-title" muted={`${done} of ${steps.length}`}>Get started</CardTitle>
        <button type="button" aria-label="Dismiss checklist" onClick={() => { try { localStorage.setItem(dismissKey(userId), "1"); } catch { /* optional */ } setDismissed(true); }}
          className={`${HIT} grid size-9 place-items-center rounded-[10px] border border-line hover:bg-well`}><X size={16} aria-hidden /></button>
      </div>
      <ol className="mt-3 space-y-3">
        {steps.map(([title, ok, hint]) => (
          <li key={title} className="flex items-start gap-3 text-sm">
            <span aria-hidden className={`mt-0.5 grid size-5 shrink-0 place-items-center rounded-full border ${ok ? "border-ink bg-ink text-bg" : "border-line"}`}>{ok && <Check size={12} strokeWidth={3} />}</span>
            <span><span className="font-semibold">{title}</span><span className="sr-only">{ok ? " (done)" : " (not done yet)"}</span><span className="block text-mute">{hint}</span></span>
          </li>
        ))}
      </ol>
    </Card>
  );
}

function WatchCard() {
  const watch = useQuery({ queryKey: ["watchlist"], queryFn: api.watchlist, refetchInterval: () => pollInterval() });
  return (
    <Card aria-labelledby="watch-title">
      <div className="flex items-start justify-between"><CardTitle id="watch-title">Watchlist</CardTitle><CornerLink to="/markets?show=watching" label="Open watchlist" /></div>
      {watch.isLoading ? <Skeleton className="mt-3 h-20 w-full" /> : !watch.data?.assets.length ? <Empty title="Nothing watched yet" body="Tap Watch on any asset to follow it here." /> : (
        <ul className="mt-2 divide-y divide-line">
          {watch.data.assets.map((a) => (
            <li key={a.symbol} className="lift"><Link to={`/assets/${a.symbol}`} className="flex min-h-14 items-center gap-3 py-2">
              <Logo symbol={a.symbol} logoUrl={a.logo_url} size={36} />
              <div className="min-w-0 flex-1"><p className="truncate font-semibold">{a.name}</p><p className="text-xs text-mute">{a.symbol}</p></div>
              <div className="text-right"><p className="font-semibold">{a.quote ? <Money value={a.quote.price} asPrice /> : dash}</p>{a.quote && <Delta percent={a.quote.change_percent} className="text-xs" />}</div>
            </Link></li>
          ))}
        </ul>
      )}
    </Card>
  );
}

export default function Dashboard() {
  const pf = usePortfolio();
  const me = useMe().data;
  const nav = useNavigate();
  const [picker, setPicker] = useState<"buy" | "sell" | null>(null);
  const [depositing, setDepositing] = useState(false);

  if (pf.isError) return <ErrorBox message="Couldn't load your portfolio." onRetry={() => pf.refetch()} />;
  const p = pf.data;
  const name = me?.name?.trim() || me?.email?.split("@")[0] || "there";
  const buy = () => setPicker("buy");

  return (
    <div className="space-y-6">
      <div className="space-y-4">
        <Headline name={name} />
        <div className="flex flex-wrap gap-2.5" role="group" aria-label="Quick actions">
          <button type="button" className={pillClass(true)} onClick={buy}>Buy</button>
          <button type="button" className={pillClass()} onClick={() => setPicker("sell")}>Sell</button>
          <button type="button" className={pillClass()} onClick={() => setDepositing(true)}>Add cash</button>
          <button type="button" className={pillClass()} onClick={() => nav("/markets?focus=1")}>Watch</button>
        </div>
      </div>
      <MarketsStrip />
      <WaitingOrders />
      {p ? (
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_380px]">
          <div className="min-w-0 space-y-5"><PortfolioCard p={p} /><Holdings p={p} onBuy={buy} /></div>
          <div className="min-w-0 space-y-5"><AccountsCard p={p} /><Checklist userId={me?.id} /><WatchCard /></div>
        </div>
      ) : <div className="space-y-4"><Skeleton className="h-72 w-full" /><Skeleton className="h-48 w-full" /></div>}
      {picker && <SymbolPicker mode={picker} onClose={() => setPicker(null)} onPick={(a) => { setPicker(null); nav(`/assets/${a.symbol}?trade=${picker}`); }} />}
      {depositing && <DepositSheet onClose={() => setDepositing(false)} />}
    </div>
  );
}

