import { afterEach, expect } from "vitest";
import { cleanup } from "@testing-library/react";
import * as axeMatchers from "vitest-axe/matchers";
import "@testing-library/jest-dom/vitest";

expect.extend(axeMatchers);
afterEach(cleanup);

// Node's experimental localStorage can shadow jsdom's and be unusable; give tests a plain in-memory Storage.
if (typeof localStorage === "undefined" || typeof localStorage.getItem !== "function") {
  const m = new Map<string, string>();
  Object.defineProperty(globalThis, "localStorage", { configurable: true, value: {
    getItem: (k: string) => (m.has(k) ? m.get(k)! : null), setItem: (k: string, v: string) => void m.set(k, String(v)),
    removeItem: (k: string) => void m.delete(k), clear: () => m.clear(), key: (i: number) => [...m.keys()][i] ?? null, get length() { return m.size; },
  } });
}
