import { describe, expect, it } from "vitest";
import { makeKeyStore, validateTradeInput } from "./input";

describe("validateTradeInput [ORD-02]", () => {
  it.each(["1", "0.5", "1000.00", "250.5"])("accepts amount %s", (v) => expect(validateTradeInput(v, "amount")).toBeNull());
  it.each(["", " ", "0", "-1", "1e3", "NaN", "1.234", "abc", "1,000"])("rejects amount %j", (v) => expect(validateTradeInput(v, "amount")).not.toBeNull());
  it("allows 8 decimals for quantity and rejects 9", () => {
    expect(validateTradeInput("0.12345678", "quantity")).toBeNull();
    expect(validateTradeInput("0.123456789", "quantity")).not.toBeNull();
  });
});

describe("idempotency key store [UX-02]", () => {
  it("keeps the key across retries of identical inputs and changes it when inputs change", () => {
    let n = 0;
    const store = makeKeyStore(() => `k${n++}`);
    const a = store.keyFor({ side: "buy", amount: "10" });
    expect(store.keyFor({ side: "buy", amount: "10" })).toBe(a);
    expect(store.keyFor({ side: "buy", amount: "11" })).not.toBe(a);
  });
});
