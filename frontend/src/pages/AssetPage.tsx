import { useEffect, useMemo, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Star } from "lucide-react";
import { api, ApiError, type AssetDetail, type Interval, type Range } from "../lib/api";
import { ageMinutes, ago, compactNumber, dash, formatOpen, money, price, priceOrDash, qty } from "../lib/format";
import { pollInterval, useMarket, useMe } from "../lib/query";
import { Button, Card, CardTitle, Delta, ErrorBox, HIT, Logo, RangeBar, Segmented, Skeleton, Toggle } from "../components/ui";
import { Money } from "../components/Money";
import { PriceChart } from "../components/PriceChart";
import { SymbolPicker } from "../components/SymbolPicker";
import { TradeSheet } from "../components/TradeSheet";
import { useMedia } from "../components/useMedia";
import { hasVolume, INTERVAL_LABEL, RANGES, RANGE_LABEL, VALID_INTERVALS, fillsFromOrders, rangeSummary, toBars, type ChartType } from "../lib/chart";

const TYPES: { value: ChartType; label: string }[] = [{ value: "line", label: "Line" }, { value: "area", label: "Area" }, { value: "candles", label: "Candles" }];
const RANGE_PHRASE: Record<Range, string> = { "1D": "today", "1W": "past week", "1M": "past month", "3M": "past 3 months", "6M": "past 6 months", "1Y": "past year", "5Y": "past 5 years", ALL: "all time" };
const typeKey = (id?: number) => `pb_chart_type:${id ?? "anon"}`;
const readType = (id?: number): ChartType => { try { const v = localStorage.getItem(typeKey(id)); return v === "area" || v === "candles" ? v : "line"; } catch { return "line"; } };

function KeyNumbers({ a }: { a: AssetDetail }) {
  const s = a.stats, px = a.quote ? Number(a.quote.price) : null;
  const pos = (lo: string | null, hi: string | null) => (px !== null && lo && hi && Number(hi) > Number(lo) ? (px - Number(lo)) / (Number(hi) - Number(lo)) : null);
  const chg = (v: string | null) => (v === null ? <span>{dash}</span> : <Delta percent={v} />);
  const rows: [string, React.ReactNode][] = [
    ["Open", priceOrDash(s.open)], ["Yesterday's close", priceOrDash(a.quote?.previous_close)], ["Volume", compactNumber(s.volume)], ["Average volume", compactNumber(s.avg_volume)],
    ["1 month change", chg(s.change_1m_percent)], ["1 year change", chg(s.change_1y_percent)],
  ];
  return (
    <Card aria-labelledby="key-numbers">
      <CardTitle id="key-numbers">Key numbers</CardTitle>
      <dl className="mt-3 divide-y divide-line text-sm">
        {rows.map(([k, v]) => <div key={k} className="flex min-h-10 items-center justify-between"><dt className="text-mute">{k}</dt><dd className="num font-semibold">{v}</dd></div>)}
      </dl>
      {([["Today's range", s.day_low, s.day_high], ["52-week range", s.week52_low, s.week52_high]] as const).map(([label, lo, hi]) => (
        <div key={label} className="mt-4">
          <p className="mb-2 text-sm text-mute">{label}</p>
          <RangeBar position={pos(lo, hi)} label={label} />
          <div className="num mt-1.5 flex justify-between text-[13px] font-semibold"><span>{priceOrDash(lo)}</span><span>{priceOrDash(hi)}</span></div>
        </div>
      ))}
    </Card>
  );
}

export default function AssetPage() {
  const { symbol = "" } = useParams();
  const [sp, setSp] = useSearchParams();
  const qc = useQueryClient();
  const me = useMe().data;
  const desktop = useMedia("(min-width: 768px)");
  const market = useMarket();

  const [range, setRange] = useState<Range>("1M");
  const [interval, setIntervalSel] = useState<Interval | null>(null);
  const [type, setTypeState] = useState<ChartType>(() => readType(me?.id));
  const [vol, setVol] = useState(false);
  const [s10, setS10] = useState(false);
  const [s20, setS20] = useState(false);
  const [cmp, setCmp] = useState<string | null>(null);
  const [picking, setPicking] = useState(false);
  const [panel, setPanel] = useState<{ side: "buy" | "sell"; n: number }>({ side: "buy", n: 0 });
  const [sheet, setSheet] = useState(false);
  const setType = (t: ChartType) => { setTypeState(t); try { localStorage.setItem(typeKey(me?.id), t); } catch { /* optional */ } };
  useEffect(() => { setTypeState(readType(me?.id)); }, [me?.id]);
  useEffect(() => { setCmp(null); setIntervalSel(null); }, [symbol]);

  // CHT-15: `?trade=buy|sell` (from the Buy / Sell pills) opens the panel on that side.
  const trade = sp.get("trade");
  useEffect(() => {
    if (trade !== "buy" && trade !== "sell") return;
    setPanel((p) => ({ side: trade, n: p.n + 1 }));
    if (!desktop) setSheet(true);
    const next = new URLSearchParams(sp); next.delete("trade"); setSp(next, { replace: true });
  }, [trade]); // eslint-disable-line react-hooks/exhaustive-deps

  const asset = useQuery({ queryKey: ["asset", symbol], queryFn: () => api.asset(symbol), refetchInterval: () => pollInterval(), retry: (n, e) => !(e instanceof ApiError) && n < 2 });
  const candles = useQuery({ queryKey: ["candles", symbol, range, interval], queryFn: () => api.candles(symbol, range, interval ?? undefined), staleTime: 60_000 });
  const effInterval = candles.data?.interval ?? interval ?? "1d";
  const cmpQ = useQuery({ queryKey: ["candles", cmp, range, effInterval], enabled: !!cmp && !!candles.data, queryFn: () => api.candles(cmp as string, range, effInterval === "5m" ? undefined : effInterval), staleTime: 60_000 });
  const orders = useQuery({ queryKey: ["orders", "asset", symbol], queryFn: () => api.orders({ symbol, status: "filled", limit: 200 }), staleTime: 30_000 });

  const bars = useMemo(() => toBars(candles.data?.candles ?? []), [candles.data]);
  const fills = useMemo(() => fillsFromOrders(orders.data?.orders ?? []), [orders.data]);
  const cmpPoints = useMemo(() => toBars(cmpQ.data?.candles ?? []).map((b) => ({ time: b.time, value: b.close })), [cmpQ.data]);
  const summary = useMemo(() => rangeSummary(bars), [bars]);
  const canVol = hasVolume(bars);
  const intervals = VALID_INTERVALS[range];

  const toggle = useMutation({
    mutationFn: async (watched: boolean) => { await (watched ? api.unwatch(symbol) : api.watch(symbol)); },
    onMutate: async (watched) => {
      await qc.cancelQueries({ queryKey: ["asset", symbol] });
      const prev = qc.getQueryData<AssetDetail>(["asset", symbol]);
      if (prev) qc.setQueryData(["asset", symbol], { ...prev, watched: !watched });
      return { prev } as { prev: AssetDetail | undefined };
    },
    onError: (_e, _v, ctx) => ctx?.prev && qc.setQueryData(["asset", symbol], ctx.prev),
    onSettled: () => { qc.invalidateQueries({ queryKey: ["watchlist"] }); qc.invalidateQueries({ queryKey: ["assets"] }); },
  });

  if (asset.isError) {
    const nf = asset.error instanceof ApiError && asset.error.code === "not_found";
    return <div className="space-y-3"><Link to="/markets" className={`${HIT} text-sm font-semibold text-mute hover:text-ink`}>← Markets</Link><ErrorBox message={nf ? `We don't list “${symbol}”.` : "Couldn't load this asset."} onRetry={nf ? undefined : () => asset.refetch()} /></div>;
  }
  const a = asset.data;
  if (!a) return <div className="space-y-3"><Skeleton className="h-8 w-48" /><Skeleton className="h-12 w-64" /><Skeleton className="h-72 w-full" /></div>;

  const closed = a.kind !== "crypto" && !!market.data && !market.data.open;
  const age = ageMinutes(a.quote?.as_of);
  const noPrice = !a.quote;
  const crypto = a.kind === "crypto";
  // UX-05: trading is disabled while the price is missing or stale.
  const stale = !!a.quote && (crypto ? age > 5 : !closed && age > 15);
  const blockedReason = noPrice ? "Price unavailable — trading is disabled for now." : stale ? "Delayed price — trading is disabled until the price updates." : null;
  const queueNote = closed && !blockedReason ? `${market.data?.next_open ? formatOpen(market.data.next_open) : "The US market is closed"}. Orders you place now are queued and fill at the first price after the open. You can cancel until then.` : null;
  const openSheet = (side: "buy" | "sell") => { setPanel((p) => ({ side, n: p.n + 1 })); setSheet(true); };
  const chartLabel = `${a.symbol} price chart, ${RANGE_LABEL[range]}${cmp ? `, compared with ${cmp}` : ""}`;
  const rangeOpts = RANGES.map((r) => ({ value: r, label: RANGE_LABEL[r] }));

  const tradePanel = blockedReason
    ? <Card><p role="status" className="text-sm font-medium">{blockedReason}</p></Card>
    : (
      <div className="space-y-3">
        {queueNote && <p role="status" className=" border border-line bg-card p-3 text-sm rounded-md"><span className="font-semibold">Market closed.</span> {queueNote}</p>}
        {desktop && <TradeSheet key={`${panel.n}-${a.symbol}`} inline asset={a} initialSide={panel.side} onClose={() => setPanel((p) => ({ ...p, n: p.n + 1 }))} />}
      </div>
    );

  return (
    <div className="space-y-5">
      <Link to="/markets" className={`${HIT} inline-flex text-sm font-semibold text-mute hover:text-ink`}>← Markets</Link>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <Logo symbol={a.symbol} logoUrl={a.logo_url} size={52} />
          <div>
            <h1 className="m-0 text-[28px] font-semibold leading-tight tracking-[-0.02em]">{a.name}</h1>
            <p className="text-sm text-mute">{a.symbol} · <span className="capitalize">{a.kind}</span>{a.sector && a.sector !== "Crypto" ? ` · ${a.sector}` : ""}</p>
          </div>
        </div>
        <Button variant="secondary" pill aria-pressed={a.watched} onClick={() => toggle.mutate(a.watched)}>
          <Star size={16} aria-hidden fill={a.watched ? "currentColor" : "none"} />{a.watched ? "Watching" : "Watch"}
        </Button>
      </div>

      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <Card>
            <div className="flex flex-wrap items-end justify-between gap-3">
              <div>
                <p className="text-[44px] font-semibold leading-none tracking-[-0.03em]">{a.quote ? <Money value={a.quote.price} asPrice /> : dash}</p>
                <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
                  {a.quote && <span><Delta value={a.quote.change} percent={a.quote.change_percent} money={price} suffix="today" /></span>}
                  {summary && range !== "1D" && <span data-testid="range-summary"><Delta value={summary.change} percent={summary.percent} money={price} suffix={RANGE_PHRASE[range]} /></span>}
                  {a.quote && (a.quote.stale || age > 2) && (crypto || market.data?.open) && <span className=" border border-line px-2 py-0.5 text-[13px] text-mute rounded-md">Delayed · updated {ago(a.quote.as_of)}</span>}
                </div>
                <p className="mt-1 text-[13px] text-mute">{crypto ? "Crypto trades 24/7" : market.data?.open ? "US market open" : "US market closed"}</p>
              </div>
            </div>

            <div className="mt-5 flex flex-wrap items-center justify-between gap-3">
              <Segmented label="Range" options={rangeOpts} value={range} onChange={(r) => { setRange(r); setIntervalSel(null); }} />
              <div className="flex flex-wrap items-center gap-2">
                <Segmented label="Chart type" options={TYPES} value={type} onChange={setType} />
                {type === "candles" && (
                  <Segmented label="Candle size" options={intervals.map((i) => ({ value: i, label: INTERVAL_LABEL[i] }))} value={interval ?? (intervals.length === 1 ? intervals[0] : null)} onChange={(i) => setIntervalSel(i)} />
                )}
              </div>
            </div>

            <div className="mt-4">
              {candles.isLoading ? <Skeleton className="h-[360px] w-full" />
                : candles.isError ? <ErrorBox message="Couldn't load the chart." onRetry={() => candles.refetch()} />
                : bars.length === 0 ? <p className="grid h-[360px] place-items-center text-sm text-mute">No price history for this range</p>
                : <PriceChart bars={bars} type={type} range={range} interval={effInterval} label={chartLabel} volume={vol && canVol} sma10={s10} sma20={s20} fills={fills}
                    avgCost={a.position ? Number(a.position.average_cost) : null}
                    compare={cmp && cmpPoints.length ? { label: cmp, points: cmpPoints, mode: "rebase" } : null} />}
            </div>

            <div className="mt-4 flex flex-wrap items-center gap-2" role="group" aria-label="Chart overlays">
              {canVol && <Toggle on={vol} onClick={() => setVol(!vol)} dot="var(--bar2)">Volume</Toggle>}
              <Toggle on={s10} onClick={() => setS10(!s10)} dot="var(--sma1)" disabled={bars.length < 10}>SMA 10</Toggle>
              <Toggle on={s20} onClick={() => setS20(!s20)} dot="var(--sma2)" disabled={bars.length < 20}>SMA 20</Toggle>
              {cmp ? <Toggle on onClick={() => setCmp(null)} dot="var(--bar2)">vs {cmp} ✕</Toggle> : <Toggle on={false} onClick={() => setPicking(true)}>Compare</Toggle>}
              {fills.length > 0 && <span className="text-[13px] text-mute">Arrows mark your trades</span>}
            </div>
            {cmp && <p className="mt-2 text-[13px] text-mute">Both lines start at 0% on the left, so you can compare how much each moved.</p>}
          </Card>

          {a.position && (
            <Card aria-labelledby="your-position">
              <CardTitle id="your-position">Your position</CardTitle>
              <dl className="mt-3 grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
                <div><dt className="text-mute">Quantity</dt><dd className="num font-semibold">{qty(a.position.quantity)}</dd></div>
                <div><dt className="text-mute">Avg. cost</dt><dd className="num font-semibold">{price(a.position.average_cost)}</dd></div>
                <div><dt className="text-mute">Market value</dt><dd className="num font-semibold">{a.position.market_value ? money(a.position.market_value) : dash}</dd></div>
                <div><dt className="text-mute">Return</dt><dd className="num font-semibold">{a.position.market_value ? <Delta percent={((Number(a.position.market_value) / (Number(a.position.quantity) * Number(a.position.average_cost)) - 1) * 100).toFixed(2)} /> : dash}</dd></div>
              </dl>
            </Card>
          )}
        </div>

        <aside className="min-w-0 space-y-5 lg:sticky lg:top-24 lg:self-start" aria-label="Trade and key numbers">
          {tradePanel}
          <KeyNumbers a={a} />
        </aside>
      </div>

      {!desktop && !blockedReason && (
        <div className="fixed inset-x-0 bottom-14 z-20 grid grid-cols-2 gap-2 border-t border-line bg-bg/95 p-3 backdrop-blur">
          <Button onClick={() => openSheet("buy")}>{closed ? "Buy at the open" : "Buy"}</Button>
          <Button variant="secondary" disabled={!a.position} onClick={() => openSheet("sell")}>{closed ? "Queue sell" : "Sell"}</Button>
        </div>
      )}
      {!desktop && sheet && <TradeSheet key={panel.n} asset={a} initialSide={panel.side} onClose={() => setSheet(false)} />}
      {picking && <SymbolPicker mode="compare" onClose={() => setPicking(false)} onPick={(x) => { setCmp(x.symbol); setPicking(false); }} />}
    </div>
  );
}


