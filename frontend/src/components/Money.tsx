import { money, price, splitMoney } from "../lib/format";

/**
 * DSN-04: headline and list amounts render with raised small cents ("$104,862" + superscript "40").
 * Screen readers always get the full amount ("$104,862.40"); the split rendering is hidden from them.
 * Sub-dollar prices (crypto) stay as plain text so no precision is hidden.
 */
export function Money({ value, className = "", asPrice = false }: { value: string | number; className?: string; asPrice?: boolean }) {
  const n = Number(value);
  if (asPrice && Math.abs(n) < 1 && n !== 0) return <span className={`num ${className}`}>{price(value)}</span>;
  const { negative, whole, cents } = splitMoney(value);
  return (
    <span className={`num ${className}`}>
      <span className="sr-only">{money(value)}</span>
      <span aria-hidden="true">{negative ? "−" : ""}${whole}<span className="cents">{cents}</span></span>
    </span>
  );
}
