import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

const read = (p: string) => readFileSync(p, "utf8");

describe("project gates", () => {
  it("rule_coverage scans every v3 prefix and the v3 PRD [QA-03]", () => {
    const s = read("../script/rule_coverage");
    for (const p of ["DSN", "HOME", "CHT", "FLT", "DAT", "WEL", "QA"]) expect(s).toContain(p);
    expect(s).toContain("PRD-ui-v3.md");
  });
  it("CI runs check:api, typecheck and tests [QA-04]", () => {
    const ci = read("../.github/workflows/ci.yml");
    expect(ci).toMatch(/npm run check:api/);
    expect(ci).toMatch(/npm run typecheck/);
    expect(ci).toMatch(/npm test/);
  });
  it("keeps the v2 behaviour tests in place [QA-05]", () => {
    for (const f of ["src/components/TradeSheet.test.tsx", "src/pages/Activity.test.tsx", "src/pages/Dashboard.test.tsx"]) expect(read(f).length).toBeGreaterThan(100);
  });
  it("README documents the new endpoints, theme, how to run, deviations and what was browser-verified [QA-06, QA-07]", () => {
    const r = read("../README.md");
    for (const h of ["/market/overview", "data-theme", "docker compose up", "UI v3 deviations", "Browser verification (QA-06)", "check:api"]) expect(r).toContain(h);
  });
});
