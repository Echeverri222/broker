import { describe, expect, it } from "vitest";
import { describeBar, fillsByBar, fillsFromOrders, hasVolume, pointsToBars, rangeSummary, rebase, rebasePair, sma, snapToBar, tickLabel, tipToSpeech, toBars, VALID_INTERVALS, type Bar } from "./chart";
import type { Order } from "./api";

const bars = (closes: number[], volume: number | null = 100): Bar[] => closes.map((c, i) => ({ time: 1000 + i * 86400, open: c - 1, high: c + 1, low: c - 2, close: c, volume }));

describe("SMA [CHT-05]", () => {
  it("averages the last N closes and starts at the Nth candle", () => {
    const out = sma(bars([1, 2, 3, 4, 5]), 3);
    expect(out.map((p) => p.value)).toEqual([2, 3, 4]);
    expect(out[0].time).toBe(1000 + 2 * 86400);
  });
  it("is empty when there are fewer candles than the period, so the overlay can hide", () => {
    expect(sma(bars([1, 2, 3]), 10)).toEqual([]);
    expect(sma(bars([]), 10)).toEqual([]);
  });
  it("matches a brute-force average on a longer series", () => {
    const closes = Array.from({ length: 60 }, (_, i) => 100 + Math.sin(i) * 10);
    const b = bars(closes);
    const got = sma(b, 20);
    got.forEach((p, k) => expect(p.value).toBeCloseTo(closes.slice(k, k + 20).reduce((a, c) => a + c, 0) / 20, 9));
  });
});

describe("compare rebasing [CHT-07]", () => {
  it("sets the first visible close to 100 on both series", () => {
    const primary = [{ time: 10, value: 50 }, { time: 20, value: 55 }, { time: 30, value: 60 }];
    const compare = [{ time: 5, value: 1 }, { time: 10, value: 200 }, { time: 20, value: 210 }, { time: 30, value: 180 }, { time: 40, value: 1 }];
    const r = rebasePair(primary, compare);
    [100, 110, 120].forEach((v, i) => expect(r.primary[i].value).toBeCloseTo(v, 9));
    [100, 105, 90].forEach((v, i) => expect(r.compare[i].value).toBeCloseTo(v, 9)); // cut to the primary window, then rebased
    expect(r.compare.map((p) => p.time)).toEqual([10, 20, 30]);
  });
  it("returns nothing rather than dividing by zero", () => {
    expect(rebase([{ time: 1, value: 0 }])).toEqual([]);
    expect(rebasePair([], [{ time: 1, value: 1 }])).toEqual({ primary: [], compare: [] });
  });
});

describe("range summary [CHT-10]", () => {
  it("reports open-to-now change in dollars and percent", () => {
    const s = rangeSummary([{ time: 1, open: 100, high: 120, low: 95, close: 110, volume: null }, { time: 2, open: 110, high: 130, low: 100, close: 125, volume: null }]);
    expect(s?.change).toBe(25);
    expect(s?.percent).toBe(25);
    expect(rangeSummary([])).toBeNull();
  });
});

describe("volume availability [CHT-04]", () => {
  it("is false when every candle has null volume (toggle hidden)", () => {
    expect(hasVolume(bars([1, 2], null))).toBe(false);
    expect(hasVolume(bars([1, 2], 5))).toBe(true);
  });
  it("keeps null volume as null when converting candles", () => {
    const b = toBars([{ time: 2, open: "1", high: "1", low: "1", close: "1", volume: null }, { time: 1, open: "1", high: "2", low: "1", close: "2", volume: "40" }, { time: 1, open: "1", high: "2", low: "1", close: "3", volume: "41" }]);
    expect(b.map((x) => [x.time, x.close, x.volume])).toEqual([[1, 3, 41], [2, 1, null]]);
    expect(pointsToBars([{ time: 1, value: 3 }])[0].volume).toBeNull();
  });
});

describe("your trades [CHT-06]", () => {
  const order = (over: Partial<Order>): Order => ({ id: 1, symbol: "AAPL", name: "Apple", kind: "stock", side: "buy", quantity: "2.00000000", price: "185.00000000", total: "370.00", realized_pnl: null, status: "filled", filled_at: new Date(1000 * 1000 + 5000).toISOString(), created_at: new Date(1000 * 1000).toISOString(), amount: null, requested_quantity: null, sell_all: false, reserved_cash: "0.00", reject_reason: null, ...over });
  it("marks only filled orders, never pending, cancelled or rejected ones", () => {
    const fills = fillsFromOrders([order({}), order({ id: 2, status: "pending", filled_at: null, quantity: null, price: null }), order({ id: 3, status: "cancelled", filled_at: null }), order({ id: 4, status: "rejected", filled_at: null })]);
    expect(fills).toHaveLength(1);
    expect(fills[0]).toMatchObject({ side: "buy", quantity: 2, price: 185 });
  });
  it("snaps a fill to the candle it happened in and ignores fills outside the window", () => {
    expect(snapToBar([10, 20, 30], 25)).toBe(1);
    expect(snapToBar([10, 20, 30], 5)).toBeNull();
    const b = bars([1, 2, 3]);
    const inWindow = { time: b[1].time + 500, side: "buy" as const, quantity: 1, price: 2 };
    const before = { time: b[0].time - 5, side: "sell" as const, quantity: 1, price: 2 };
    const after = { time: b[2].time + 99 * 86400, side: "buy" as const, quantity: 1, price: 2 };
    const m = fillsByBar(b, [inWindow, before, after], "1d");
    expect([...m.keys()]).toEqual([1]);
  });
});

describe("tooltip content [CHT-08]", () => {
  it("lists open, high, low, close and volume for candles with the change vs the previous candle", () => {
    const tip = describeBar(bars([10, 12]), 1, { type: "candles", interval: "1d", range: "1M" })!;
    expect(tip.rows.map((r) => r.label)).toEqual(["Open", "High", "Low", "Close", "Volume"]);
    expect(tip.change).toEqual({ text: "▲ 2.00 (20.00%) vs previous", tone: "gain" });
    expect(tipToSpeech(tip)).toMatch(/Close 12\.00.*Up 2\.00/);
  });
  it("shows Price for lines, and says what was bought on that candle", () => {
    const tip = describeBar(bars([10]), 0, { type: "line", interval: "1d", range: "1M", fills: [{ time: 1, side: "buy", quantity: 2.5, price: 185 }] })!;
    expect(tip.rows[0]).toEqual({ label: "Price", value: "10.00" });
    expect(tip.change).toBeNull();
    expect(tip.trades).toEqual(["Bought 2.5 at $185.00"]);
  });
});

describe("axis helpers [CHT-02, CHT-09]", () => {
  it("only offers candle sizes the API accepts", () => {
    expect(VALID_INTERVALS["1D"]).toEqual(["1h"]);
    expect(VALID_INTERVALS.ALL).toEqual(["1w"]);
    expect(VALID_INTERVALS["3M"]).toEqual(["1d", "1w"]);
  });
  it("adapts time labels to the range", () => {
    const t = Date.UTC(2026, 10, 11, 15, 30) / 1000;
    expect(tickLabel(t, 0, "ALL")).toMatch(/2026/);
    expect(tickLabel(t, 1, "1M")).toBe("Nov");
    expect(tickLabel(t, 1, "5Y")).toMatch(/Nov/);
    expect(tickLabel(t, 2, "1M")).toBe("Nov 11");
  });
});
