import { describe, expect, it, beforeEach } from "vitest";
import { readFileSync } from "node:fs";
import { applyTheme, readPref, savePref, THEME_KEY } from "./theme";

const css = readFileSync("src/index.css", "utf8");
const html = readFileSync("index.html", "utf8");
const block = (sel: string) => css.slice(css.indexOf(sel)).split("}")[0];
const tokens = (b: string) => Object.fromEntries([...b.matchAll(/--([a-z0-9-]+):\s*(#[0-9A-Fa-f]{6})/g)].map((m) => [m[1], m[2]]));
const lum = (hex: string) => {
  const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
};
const ratio = (a: string, b: string) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

describe("theme [DSN-02]", () => {
  beforeEach(() => { try { localStorage.clear(); } catch { /* ignore */ } });
  it("persists the choice and applies data-theme to <html>", () => {
    savePref("dark");
    expect(localStorage.getItem(THEME_KEY)).toBe("dark");
    expect(document.documentElement.dataset.theme).toBe("dark");
    expect(readPref()).toBe("dark");
    applyTheme("light");
    expect(document.documentElement.dataset.theme).toBe("light");
  });
  it("sets the theme before first paint with an inline script, so there is no flash", () => {
    const head = html.split("</head>")[0];
    expect(head).toMatch(/<script>[^<]*pb_theme[^<]*data-theme|<script>[^<]*dataset\.theme/s);
    expect(head.indexOf("pb_theme")).toBeLessThan(head.indexOf("/src/main.tsx") === -1 ? Infinity : head.indexOf("/src/main.tsx"));
  });
});

describe("tokens and contrast [DSN-01, DSN-03, DSN-05, DSN-08, DSN-09, DSN-10]", () => {
  const light = tokens(block(":root {")), dark = tokens(block(':root[data-theme="dark"]'));
  it("defines every token in both themes (DSN-01)", () => {
    for (const k of ["bg", "card", "well", "line", "ink", "mute", "accent", "gain", "loss", "amber", "chart", "bench"]) {
      expect(light[k], `light ${k}`).toBeTruthy();
      expect(dark[k], `dark ${k}`).toBeTruthy();
    }
  });
  it.each([["light", light], ["dark", dark]] as const)("text pairs meet WCAG AA in %s (DSN-05)", (_n, t) => {
    expect(ratio(t.ink, t.bg)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(t.ink, t.card)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(t.mute, t.bg)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(t.mute, t.card)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(t.gain, t.card)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(t.loss, t.card)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(t["accent-ink"], t.accent)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(t["amber-ink"], t["amber-bg"])).toBeGreaterThanOrEqual(4.5);
  });
  it("uses Inter with tabular figures (DSN-03), reduced motion (DSN-08), 3px focus ring (DSN-10)", () => {
    expect(css).toMatch(/font-sans:\s*Inter/);
    expect(css).toMatch(/tnum/);
    expect(css).toMatch(/prefers-reduced-motion/);
    expect(css).toMatch(/outline:\s*3px/);
  });
  it("caps content at 1200px with 32px / 16px gutters (DSN-09)", () => {
    expect(css).toMatch(/--gutter:\s*32px/);
    expect(css).toMatch(/--gutter:\s*16px/);
    expect(readFileSync("src/components/Layout.tsx", "utf8")).toMatch(/max-w-\[1200px\]/);
  });
  it("has no hard-coded hex colours in components (DSN-01)", () => {
    for (const f of ["Layout", "PriceChart", "ui", "Money", "TradeSheet", "SymbolPicker"]) {
      expect(readFileSync(`src/components/${f}.${f === "Money" || f === "ui" || f === "PriceChart" || f === "Layout" || f === "TradeSheet" || f === "SymbolPicker" ? "tsx" : "ts"}`, "utf8")).not.toMatch(/#[0-9a-fA-F]{6}\b/);
    }
  });
});
