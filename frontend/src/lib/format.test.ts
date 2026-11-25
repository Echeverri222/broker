import { describe, expect, it } from "vitest";
import { dir, formatOpen, money, pct, price, qty, signed } from "./format";
import { POLL } from "./query";

describe("format", () => {
  it("formats negative, zero, large and many-decimal values", () => {
    expect(money("-1234.5")).toBe("-$1,234.50");
    expect(money("0")).toBe("$0.00");
    expect(money("123456789.10")).toBe("$123,456,789.10");
    expect(price("0.00012345")).toBe("$0.000123");
    expect(qty("0.12345678")).toBe("0.12345678");
  });

  it("always pairs gains and losses with a sign, and a direction not only a colour [UX-06]", () => {
    expect(signed("12.5")).toBe("+$12.50");
    expect(signed("-12.5")).toBe("−$12.50");
    expect(pct("0.5")).toBe("+0.50%");
    expect(pct("-0.5")).toBe("−0.50%");
    expect(pct("0")).toBe("0.00%");
    expect([dir("1"), dir("-1"), dir("0")]).toEqual(["up", "down", "flat"]);
  });

  it("states when the market opens next in Eastern time [UX-04]", () => {
    // Saturday 2026-03-07 16:00 UTC -> opens Monday 09:30 EDT = 13:30 UTC
    const text = formatOpen("2026-03-09T13:30:00Z", new Date("2026-03-07T16:00:00Z"));
    expect(text).toBe("Market opens Mon 9:30 AM ET (in 45h 30m)");
  });

  it("polls every 15 seconds [UX-10]", () => {
    expect(POLL).toBe(15_000);
  });
});
