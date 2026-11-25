import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { Money } from "./Money";
import { splitMoney } from "../lib/format";

describe("<Money> [DSN-04]", () => {
  it("renders raised cents visually and the full amount for screen readers", () => {
    const { container } = render(<Money value="104862.40" />);
    expect(screen.getByText("$104,862.40")).toBeTruthy(); // sr-only full amount
    const visible = container.querySelector("[aria-hidden='true']")!;
    expect(visible.textContent).toBe("$104,86240");
    expect(visible.querySelector(".cents")?.textContent).toBe("40");
  });
  it("keeps sign and rounds half away from zero", () => {
    expect(splitMoney("-1234.505")).toEqual({ negative: true, whole: "1,234", cents: "51" });
    expect(splitMoney("0.004").negative).toBe(false);
  });
  it("leaves sub-dollar prices as plain text so no precision is hidden", () => {
    const { container } = render(<Money value="0.123456" asPrice />);
    expect(container.textContent).toBe("$0.123456");
    expect(container.querySelector(".cents")).toBeNull();
  });
});
