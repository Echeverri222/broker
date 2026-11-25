import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";

// A recording stand-in for lightweight-charts: jsdom has no canvas.
const log: { crosshair: unknown[][]; cleared: number; series: string[]; markers: number; priceLines: number } = { crosshair: [], cleared: 0, series: [], markers: 0, priceLines: 0 };
vi.mock("lightweight-charts", () => {
  const series = (name: string) => ({ setData: () => {}, applyOptions: () => {}, createPriceLine: () => { log.priceLines++; } , __name: name });
  const mk = (name: string) => name;
  return {
    AreaSeries: mk("area"), CandlestickSeries: mk("candles"), HistogramSeries: mk("volume"), LineSeries: mk("line"),
    ColorType: { Solid: "solid" }, CrosshairMode: { Normal: 0 }, LineStyle: { Solid: 0, Dotted: 1, Dashed: 2, LargeDashed: 3 },
    createSeriesMarkers: () => { log.markers++; },
    createChart: () => ({
      addSeries: (kind: string) => { log.series.push(kind); return series(kind); },
      panes: () => [{ setStretchFactor: () => {} }, { setStretchFactor: () => {} }],
      timeScale: () => ({ fitContent: () => {}, timeToCoordinate: () => 100 }),
      subscribeCrosshairMove: () => {}, setCrosshairPosition: (...a: unknown[]) => { log.crosshair.push(a); }, clearCrosshairPosition: () => { log.cleared++; },
      applyOptions: () => {}, remove: () => {},
    }),
  };
});
import { PriceChart } from "./PriceChart";
import { barsToPoints } from "../lib/chart";

const T0 = 1_700_000_000;
const bars = Array.from({ length: 30 }, (_, i) => ({ time: T0 + i * 86400, open: 100 + i, high: 103 + i, low: 98 + i, close: 101 + i, volume: 1000 + i }));
const base = { bars, range: "1M" as const, interval: "1d" as const, label: "AAPL price chart" };

describe("PriceChart", () => {
  beforeEach(() => { log.crosshair = []; log.cleared = 0; log.series = []; log.markers = 0; log.priceLines = 0; });

  it("moves a crosshair with the arrow keys and announces the values [CHT-08, QA-02]", () => {
    render(<PriceChart {...base} type="line" />);
    const chart = screen.getByRole("application", { name: /aapl price chart/i });
    chart.focus();
    fireEvent.keyDown(chart, { key: "ArrowLeft" });
    expect(log.crosshair.length).toBe(1);
    const first = log.crosshair[0][0] as number;
    fireEvent.keyDown(chart, { key: "ArrowLeft" });
    expect((log.crosshair[1][0] as number)).toBeLessThan(first);
    fireEvent.keyDown(chart, { key: "Home" });
    expect(log.crosshair.at(-1)![0]).toBe(101);
    fireEvent.keyDown(chart, { key: "End" });
    expect(log.crosshair.at(-1)![0]).toBe(130);
    expect(screen.getByTestId("chart-live").textContent).toMatch(/130/);
    expect(screen.getByTestId("chart-tooltip")).toBeTruthy();
    fireEvent.blur(chart);
    expect(log.cleared).toBe(1);
    expect(screen.queryByTestId("chart-tooltip")).toBeNull();
  });

  it("draws candles, volume in its own pane, and the averages without refetching [CHT-01, CHT-04, CHT-05, CHT-13]", () => {
    const { rerender } = render(<PriceChart {...base} type="candles" volume sma10 sma20 />);
    expect(log.series).toEqual(["candles", "line", "line", "volume"]);
    log.series = [];
    rerender(<PriceChart {...base} type="line" />);
    expect(log.series).toEqual(["line"]);
  });

  it("marks fills and shows the average cost line [CHT-06]", () => {
    render(<PriceChart {...base} type="line" avgCost={105} fills={[{ time: T0 + 5 * 86400 + 60, side: "buy", quantity: 1, price: 106 }]} />);
    expect(log.markers).toBe(1);
    expect(log.priceLines).toBe(1);
  });

  it("adds a compare line rebased to the first close [CHT-07]", () => {
    render(<PriceChart {...base} type="line" compare={{ label: "SPY", points: barsToPoints(bars), mode: "rebase" }} />);
    expect(log.series).toEqual(["line", "line"]);
  });
});
