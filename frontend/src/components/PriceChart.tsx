import { useEffect, useMemo, useRef, useState } from "react";
import {
  AreaSeries, CandlestickSeries, ColorType, CrosshairMode, HistogramSeries, LineSeries, LineStyle, createChart, createSeriesMarkers,
  type IChartApi, type ISeriesApi, type SeriesMarker, type Time, type UTCTimestamp,
} from "lightweight-charts";
import type { Interval, Range } from "../lib/api";
import {
  barsToPoints, describeBar, fillsByBar, rebase, rebaseBars, signedPct, sma, tickLabel, tipToSpeech,
  type Bar, type ChartType, type Fill, type Pt, type Tip,
} from "../lib/chart";
import { useResolvedTheme } from "../lib/theme";

export interface CompareSeries { label: string; points: Pt[]; mode: "rebase" | "overlay" }
export interface PriceChartProps {
  bars: Bar[]; type: ChartType; range: Range; interval: Interval; label: string; height?: number;
  volume?: boolean; sma10?: boolean; sma20?: boolean; fills?: Fill[]; avgCost?: number | null; compare?: CompareSeries | null;
}

const cssVar = (n: string) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
/** Adds an alpha channel to a #rrggbb / #rgb / rgb() token value (the canvas needs concrete colours, not var()). */
export function withAlpha(color: string, a: number): string {
  const hex = color.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
  if (hex) {
    const h = hex[1].length === 3 ? [...hex[1]].map((c) => c + c).join("") : hex[1];
    return `rgba(${parseInt(h.slice(0, 2), 16)}, ${parseInt(h.slice(2, 4), 16)}, ${parseInt(h.slice(4, 6), 16)}, ${a})`;
  }
  const rgb = color.match(/rgba?\(([^)]+)\)/);
  if (rgb) { const [r, g, b] = rgb[1].split(/[,\s/]+/).filter(Boolean); return `rgba(${r}, ${g}, ${b}, ${a})`; }
  return color;
}

type Auto = { priceRange: { minValue: number; maxValue: number } | null } | null;
// A flat series (new account) would otherwise zoom into cents; keep at least a 2% window so it reads as "no change".
const padFlat = (orig: () => Auto): Auto => {
  const r = orig();
  if (!r?.priceRange) return r;
  const { minValue, maxValue } = r.priceRange;
  const mid = (minValue + maxValue) / 2, minSpan = Math.abs(mid) * 0.02;
  return maxValue - minValue >= minSpan ? r : { ...r, priceRange: { minValue: mid - minSpan / 2, maxValue: mid + minSpan / 2 } };
};

const ts = (t: number) => t as UTCTimestamp;

export function PriceChart({ bars, type, range, interval, label, height = 360, volume = false, sma10 = false, sma20 = false, fills = [], avgCost = null, compare = null }: PriceChartProps) {
  const host = useRef<HTMLDivElement>(null);
  const theme = useResolvedTheme();
  const percent = compare?.mode === "rebase";
  // CHT-07: while comparing, the primary series is rebased to 100 at its first close and the axis shows % change.
  const shown = useMemo(() => (percent ? rebaseBars(bars) : bars), [bars, percent]);
  const cmpPoints = useMemo(() => {
    if (!compare || !shown.length) return [];
    if (compare.mode === "overlay") return compare.points;
    const from = shown[0].time, to = shown[shown.length - 1].time;
    return rebase(compare.points.filter((p) => p.time >= from && p.time <= to));
  }, [compare, shown]);
  const fillMap = useMemo(() => fillsByBar(shown, fills, interval), [shown, fills, interval]);
  const lineType: ChartType = type;

  // Crosshair state lives in React so the tooltip, the keyboard and the live region all read the same thing (CHT-08).
  const [active, setActive] = useState<number | null>(null);
  const [x, setX] = useState(0);
  const [width, setWidth] = useState(0);
  const pinned = useRef(false);
  const chartRef = useRef<IChartApi | null>(null);
  const seriesRef = useRef<ISeriesApi<"Line" | "Area" | "Candlestick"> | null>(null);
  const indexByTime = useMemo(() => new Map(shown.map((b, i) => [b.time, i])), [shown]);

  useEffect(() => {
    const el = host.current;
    if (!el || shown.length === 0) return;
    const c = { ink: cssVar("--ink"), mute: cssVar("--mute"), line: cssVar("--line"), card: cssVar("--card"), gain: cssVar("--gain"), loss: cssVar("--loss"),
                chart: cssVar("--chart"), bench: cssVar("--bench"), s1: cssVar("--sma1"), s2: cssVar("--sma2"), bar2: cssVar("--bar2") };
    const last = shown[shown.length - 1].close;
    const precision = !percent && last < 1 ? 6 : 2;
    const fmt = { type: "price" as const, precision, minMove: 1 / 10 ** precision };
    const chart = createChart(el, {
      autoSize: true, height,
      layout: { background: { type: ColorType.Solid, color: "transparent" }, textColor: c.mute, fontFamily: "Inter, system-ui, sans-serif", fontSize: 12, attributionLogo: false,
                panes: { separatorColor: c.line, separatorHoverColor: c.line, enableResize: false } },
      grid: { vertLines: { visible: false }, horzLines: { color: c.line, style: LineStyle.LargeDashed } },
      rightPriceScale: { borderVisible: false, minimumWidth: 64, scaleMargins: { top: 0.08, bottom: 0.06 } },
      timeScale: { borderVisible: false, timeVisible: interval === "5m" || interval === "1h", rightOffset: 2, tickMarkFormatter: (() => { let prev = ""; let prevT = -Infinity; return (t: Time, tt: number) => { const l = tickLabel(t as number, tt, range); const dup = l === prev && (t as number) >= prevT; prev = l; prevT = t as number; return dup ? null : l; }; })() },
      crosshair: { mode: CrosshairMode.Normal, vertLine: { style: LineStyle.Dotted, color: c.mute, width: 1, labelVisible: false }, horzLine: { style: LineStyle.Dotted, color: c.mute, width: 1 } },
      localization: percent ? { priceFormatter: (p: number) => signedPct(p - 100) } : undefined,
      handleScale: { mouseWheel: false, pinch: true, axisPressedMouseMove: false }, handleScroll: { mouseWheel: false, pressedMouseMove: true, horzTouchDrag: false, vertTouchDrag: false },
    });
    chartRef.current = chart;

    let main: ISeriesApi<"Line" | "Area" | "Candlestick">;
    if (lineType === "candles") {
      // CHT-03: up candles are hollow (outline only), down candles are filled, so direction never relies on colour alone.
      main = chart.addSeries(CandlestickSeries, { upColor: c.card, borderUpColor: c.gain, wickUpColor: c.gain, downColor: c.loss, borderDownColor: c.loss, wickDownColor: c.loss, borderVisible: true, priceFormat: fmt, priceLineVisible: false });
      main.setData(shown.map((b) => ({ time: ts(b.time), open: b.open, high: b.high, low: b.low, close: b.close })));
    } else if (lineType === "area") {
      main = chart.addSeries(AreaSeries, { lineColor: c.chart, topColor: withAlpha(c.chart, 0.16), bottomColor: withAlpha(c.chart, 0), lineWidth: 2, priceLineVisible: false, priceFormat: fmt, autoscaleInfoProvider: padFlat });
      main.setData(shown.map((b) => ({ time: ts(b.time), value: b.close })));
    } else {
      main = chart.addSeries(LineSeries, { color: c.chart, lineWidth: 2, priceLineVisible: false, priceFormat: fmt, autoscaleInfoProvider: padFlat });
      main.setData(shown.map((b) => ({ time: ts(b.time), value: b.close })));
    }
    seriesRef.current = main;

    const addLine = (pts: Pt[], color: string, opts: { dashed?: boolean; width?: 1 | 2 | 3 } = {}) => {
      if (!pts.length) return;
      const s = chart.addSeries(LineSeries, { color, lineWidth: opts.width ?? 2, lineStyle: opts.dashed ? LineStyle.Dashed : LineStyle.Solid, priceLineVisible: false, lastValueVisible: false, crosshairMarkerVisible: false, priceFormat: fmt, autoscaleInfoProvider: padFlat });
      s.setData(pts.map((p) => ({ time: ts(p.time), value: p.value })));
    };
    // CHT-05: moving averages come from the loaded candles; a period longer than the data yields nothing (chip hidden by the page).
    if (sma10) addLine(sma(shown, 10), c.s1);
    if (sma20) addLine(sma(shown, 20), c.s2);
    if (compare) addLine(cmpPoints, compare.mode === "overlay" ? c.bench : c.bar2, { dashed: compare.mode === "overlay" });

    if (volume && shown.some((b) => b.volume !== null)) {
      const vol = chart.addSeries(HistogramSeries, { priceFormat: { type: "volume" }, priceLineVisible: false, lastValueVisible: false }, 1);
      vol.setData(shown.filter((b) => b.volume !== null).map((b) => ({ time: ts(b.time), value: b.volume as number, color: withAlpha(b.close >= b.open ? c.gain : c.loss, 0.35) })));
      const panes = chart.panes();
      panes[0]?.setStretchFactor(4);
      panes[1]?.setStretchFactor(1);
    }

    // CHT-06: your fills as Buy / Sell markers, and a dashed line at what you paid on average.
    if (fillMap.size) {
      const markers: SeriesMarker<Time>[] = [];
      for (const [i, list] of fillMap) {
        for (const side of ["buy", "sell"] as const) {
          if (!list.some((f) => f.side === side)) continue;
          markers.push({ time: ts(shown[i].time), position: side === "buy" ? "belowBar" : "aboveBar", shape: side === "buy" ? "arrowUp" : "arrowDown", color: c.ink, text: side === "buy" ? "Buy" : "Sell" });
        }
      }
      createSeriesMarkers(main, markers);
    }
    if (avgCost && !percent) main.createPriceLine({ price: avgCost, color: c.ink, lineWidth: 1, lineStyle: LineStyle.Dashed, axisLabelVisible: true, title: "You paid" });

    // CHT-09: coloured tag for the latest price on the right axis.
    main.applyOptions({ lastValueVisible: true });

    chart.timeScale().fitContent();
    setWidth(el.clientWidth);
    chart.subscribeCrosshairMove((p) => {
      const i = p.time === undefined ? undefined : indexByTime.get(p.time as number);
      if (i === undefined || !p.point) { if (!pinned.current) setActive(null); return; }
      pinned.current = false;
      setActive(i); setX(p.point.x); setWidth(el.clientWidth);
    });
    return () => { chartRef.current = null; seriesRef.current = null; chart.remove(); };
  }, [shown, cmpPoints, lineType, range, interval, height, volume, sma10, sma20, compare, fillMap, avgCost, percent, theme, indexByTime]);

  // Reset the crosshair whenever the data changes underneath it.
  useEffect(() => { setActive(null); pinned.current = false; }, [bars, type, interval]);

  const tip: Tip | null = useMemo(() => (active === null ? null : describeBar(shown, active, {
    type: lineType, interval, range, fills: fillMap.get(active), percentAxis: percent, value: (b) => b.close,
  })), [active, shown, lineType, interval, range, fillMap, percent]);

  const moveTo = (i: number) => {
    const b = shown[i];
    if (!b) return;
    pinned.current = true;
    setActive(i);
    const chart = chartRef.current, series = seriesRef.current;
    if (chart && series) {
      chart.setCrosshairPosition(b.close, ts(b.time), series);
      const px = chart.timeScale().timeToCoordinate(ts(b.time));
      if (px !== null) setX(px);
      setWidth(host.current?.clientWidth ?? 0);
    }
  };
  const onKeyDown = (e: React.KeyboardEvent) => {
    const last = shown.length - 1;
    if (last < 0) return;
    const cur = active ?? last + (e.key === "ArrowRight" ? 1 : 0); // first arrow press starts from the latest candle
    let next: number | null = null;
    if (e.key === "ArrowLeft") next = Math.max(0, Math.min(last, cur) - (active === null ? 0 : 1));
    else if (e.key === "ArrowRight") next = Math.min(last, cur + (active === null ? -1 : 1));
    else if (e.key === "Home") next = 0;
    else if (e.key === "End") next = last;
    if (next === null) return;
    e.preventDefault();
    moveTo(next);
  };
  const onBlur = () => { pinned.current = false; setActive(null); chartRef.current?.clearCrosshairPosition(); };

  const hint = useMemo(() => `hint-${Math.random().toString(36).slice(2, 8)}`, []);
  const cardW = 184;
  const left = x > width / 2 ? Math.max(4, x - cardW - 14) : Math.min(Math.max(4, width - cardW - 70), x + 14);

  return (
    <div className="relative">
      <div ref={host} role="application" aria-roledescription="interactive chart" aria-label={label} aria-describedby={hint} tabIndex={0}
        onKeyDown={onKeyDown} onBlur={onBlur} style={{ height }} className="w-full" data-testid="price-chart" />
      <p id={hint} className="sr-only">Use the left and right arrow keys to move between points, and Home or End to jump to the first or last.</p>
      {tip && (
        <div data-testid="chart-tooltip" className="pointer-events-none absolute top-2 z-10 border border-line bg-card p-3 text-[13px] shadow-none rounded-md" style={{ left, width: cardW }}>
          <p className="font-semibold text-ink">{tip.title}</p>
          <dl className="mt-1.5 space-y-1">
            {tip.rows.map((r) => (
              <div key={r.label} className="flex justify-between gap-3"><dt className="text-mute">{r.label}</dt><dd className={`num font-semibold ${r.tone === "gain" ? "text-gain" : r.tone === "loss" ? "text-loss" : "text-ink"}`}>{r.value}</dd></div>
            ))}
          </dl>
          {tip.change && <p className={`mt-1.5 font-semibold ${tip.change.tone === "gain" ? "text-gain" : tip.change.tone === "loss" ? "text-loss" : "text-mute"}`}>{tip.change.text}</p>}
          {tip.trades.map((t) => <p key={t} className="mt-1 font-semibold text-ink">{t}</p>)}
        </div>
      )}
      <div role="status" aria-live="polite" className="sr-only" data-testid="chart-live">{tip ? tipToSpeech(tip) : ""}</div>
    </div>
  );
}

export { barsToPoints };
