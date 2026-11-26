import { useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { ArrowUpRight } from "lucide-react";
import { dir, pct, signed } from "../lib/format";

/** Extends a control's hit area to 44px without changing its look (DSN-10). */
export const HIT = "relative before:absolute before:-inset-y-1 before:inset-x-0 before:content-['']";

export const Skeleton = ({ className = "" }: { className?: string }) => <div className={`skeleton ${className}`} aria-hidden />;

/** DSN-06: 6px radius, 1px line border, no shadow. */
export const Card = ({ children, className = "", as: Tag = "section", ...rest }: { children: ReactNode; className?: string; as?: "section" | "div" | "aside" } & React.HTMLAttributes<HTMLElement>) => (
  <Tag {...rest} className={` rounded-md border border-line bg-card p-5 md:p-6 ${className}`}>{children}</Tag>
);

/** Card title: 18/600 with a muted second part ("Your portfolio · practice money"). */
export const CardTitle = ({ children, muted, id }: { children: ReactNode; muted?: string; id?: string }) => (
  <h2 id={id} className="m-0 text-[18px] font-semibold tracking-[-0.01em]">{children}{muted && <span className="font-medium text-mute"> · {muted}</span>}</h2>
);

/** DSN-06: 36px square corner button linking to the detail view of a card (44px hit area). */
export const CornerLink = ({ to, label }: { to: string; label: string }) => (
  <Link to={to} aria-label={label} className={`${HIT} grid size-9 shrink-0 place-items-center rounded-md border border-line text-ink hover:bg-well`}>
    <ArrowUpRight size={16} strokeWidth={2} aria-hidden />
  </Link>
);

type Variant = "primary" | "secondary" | "danger" | "ghost";
const VARIANTS: Record<Variant, string> = {
  primary: "bg-accent text-accent-ink hover:opacity-90",
  secondary: "rounded-md border border-line bg-card hover:bg-well",
  danger: "bg-loss text-bg hover:opacity-90",
  ghost: "hover:bg-well",
};
export function Button({ variant = "primary", pill = false, className = "", ...p }: React.ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; pill?: boolean }) {
  return <button {...p} className={`inline-flex min-h-11 items-center justify-center gap-2 px-4 text-[15px] font-semibold transition disabled:cursor-not-allowed disabled:opacity-50 ${pill ? " px-[18px]" : ""} ${VARIANTS[variant]} ${className}`} />;
}

/** The pill actions under the Home headline (and links styled the same way). */
export const pillClass = (primary = false) =>
  `inline-flex min-h-11 items-center gap-2 rounded-md border px-[18px] text-[15px] font-semibold ${primary ? "border-accent bg-accent text-accent-ink" : "border-line bg-card text-ink hover:bg-well"}`;

/** DSN-05: gain/loss colour only on changes, and always with an arrow. The sign is spoken by screen readers. */
export function Delta({ value, percent, money, className = "", suffix }: { value?: string | number; percent: string | number; money?: (n: number) => string; className?: string; suffix?: string }) {
  const d = dir(percent);
  const color = d === "up" ? "text-gain" : d === "down" ? "text-loss" : "text-mute";
  const arrow = d === "up" ? "▲" : d === "down" ? "▼" : "•";
  const word = d === "up" ? "Up " : d === "down" ? "Down " : "";
  const absPct = pct(percent).replace(/^[+−]/, "");
  return (
    <span className={`num inline-flex items-center gap-1 font-semibold ${color} ${className}`}>
      <span aria-hidden className="text-[0.75em]">{arrow}</span>
      <span className="sr-only">{word}</span>
      {value !== undefined && <span>{signed(value, money).replace(/^[+−]/, "")}</span>}
      <span>{value !== undefined ? `(${absPct})` : absPct}</span>
      {suffix && <span className="font-medium text-mute">{suffix}</span>}
    </span>
  );
}

/** DSN-07: the asset's own logo when it has one, otherwise an initials tile in a circle. Never an external logo service. */
export function Logo({ symbol, logoUrl, size = 44 }: { symbol: string; logoUrl?: string | null; size?: number }) {
  const [broken, setBroken] = useState(false);
  const box = { width: size, height: size };
  if (logoUrl && !broken) return <img src={logoUrl} alt="" onError={() => setBroken(true)} style={box} className="shrink-0 bg-logo rounded-full object-contain" />;
  const text = symbol.replace(/[^A-Z0-9]/gi, "").slice(0, symbol.length > 3 ? 4 : 3).toUpperCase();
  return (
    <span aria-hidden style={{ ...box, fontSize: Math.round(size * (text.length > 3 ? 0.26 : 0.3)) }}
      className="grid shrink-0 place-items-center bg-logo rounded-full font-bold tracking-tight text-ink">
      {text}
    </span>
  );
}

export function Sparkline({ data, up: upProp, width = 100, height = 32 }: { data: string[] | null | undefined; up?: boolean; width?: number; height?: number }) {
  const n = (data ?? []).map(Number).filter(Number.isFinite);
  if (n.length < 2) return <span aria-hidden style={{ width, height }} className="inline-block" />;
  const up = upProp ?? n[n.length - 1] >= n[0]; // colour follows the line itself (first to last point)
  const min = Math.min(...n), max = Math.max(...n), span = max - min || 1, pad = 3;
  const pts = n.map((v, i) => `${((i / (n.length - 1)) * width).toFixed(1)},${(height - pad - ((v - min) / span) * (height - pad * 2)).toFixed(1)}`).join(" ");
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} aria-hidden className={`shrink-0 ${up ? "text-gain" : "text-loss"}`} data-testid="sparkline">
      <polyline points={pts} fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round" strokeLinecap="round" />
    </svg>
  );
}

export interface Option<T extends string> { value: T; label: ReactNode; disabled?: boolean; title?: string }
/** The segmented control used for ranges, chart type, candle size and Buy/Sell. Real buttons; tabs by default. */
export function Segmented<T extends string>({ options, value, onChange, label, role = "tab", fill = false, large = false }: {
  options: readonly Option<T>[]; value: T | null; onChange: (v: T) => void; label: string; role?: "tab" | "radio"; fill?: boolean; large?: boolean;
}) {
  return (
    <div role={role === "tab" ? "tablist" : "radiogroup"} aria-label={label} className={`flex gap-0.5 bg-well p-[3px] ${fill ? "w-full" : "w-fit"}`}>
      {options.map((o) => {
        const on = o.value === value;
        return (
          <button key={o.value} type="button" role={role} {...(role === "tab" ? { "aria-selected": on } : { "aria-checked": on })} disabled={o.disabled} title={o.title}
            onClick={() => onChange(o.value)}
            className={`${HIT} px-3 text-[13px] font-semibold disabled:opacity-40 ${large ? "min-h-11 text-[15px]" : "min-h-9"} ${fill ? "flex-1" : ""} ${on ? "bg-card text-ink shadow-[0_1px_2px_rgb(0_0_0/0.12)]" : "text-mute hover:text-ink"}`}>
            {o.label}
          </button>
        );
      })}
    </div>
  );
}

/** Overlay toggle chip with a coloured dot (CHT-05). */
export function Toggle({ on, onClick, dot, children, disabled }: { on: boolean; onClick: () => void; dot?: string; children: ReactNode; disabled?: boolean }) {
  return (
    <button type="button" aria-pressed={on} onClick={onClick} disabled={disabled}
      className={`${HIT} inline-flex min-h-9 items-center gap-2 rounded-md border bg-card px-3 text-[13px] font-semibold disabled:opacity-40 ${on ? "border-ink text-ink" : "border-line text-mute hover:text-ink"}`}>
      <i aria-hidden className="inline-block size-[9px] rounded-full" style={{ background: on && dot ? dot : "var(--line)" }} />
      {children}
    </button>
  );
}

/** Filter chip (Markets "Show" and quick picks). */
export function FilterChip({ on, onClick, children, count, role }: { on: boolean; onClick: () => void; children: ReactNode; count?: number; role?: "radio" }) {
  return (
    <button type="button" onClick={onClick} {...(role === "radio" ? { role, "aria-checked": on } : { "aria-pressed": on })}
      className={`${HIT} inline-flex min-h-10 items-center gap-2 rounded-md border px-3.5 text-sm font-semibold ${on ? "border-ink bg-ink text-bg" : "border-line bg-card text-ink hover:bg-well"}`}>
      {children}
      {count !== undefined && <small className={`text-[13px] font-semibold ${on ? "opacity-75" : "text-mute"}`}>{count}</small>}
    </button>
  );
}

/** Marker on a low-high bar (today's range, 52-week range). `position` is 0..1. */
export function RangeBar({ position, label }: { position: number | null; label: string }) {
  const pos = position === null ? null : Math.min(1, Math.max(0, position));
  return (
    <div role="img" aria-label={pos === null ? `${label}: not available` : `${label}: ${Math.round(pos * 100)}% of the way from low to high`} title={pos === null ? undefined : `${Math.round(pos * 100)}% of the way from the low to the high`} className="relative h-1.5 bg-line">
      {pos !== null && <b className="absolute -top-1 size-3.5 -translate-x-1/2 border-[3px] border-card bg-ink rounded-full" style={{ left: `${pos * 100}%` }} />}
    </div>
  );
}

export const ErrorBox = ({ message, onRetry }: { message: string; onRetry?: () => void }) => (
  <div role="alert" className=" border border-line bg-card p-4 text-sm rounded-md">
    <p className="font-medium">{message}</p>
    {onRetry && <button onClick={onRetry} className={`${HIT} mt-2 inline-flex min-h-9 items-center font-semibold text-accent underline`}>Try again</button>}
  </div>
);

export const Empty = ({ title, body, cta, action }: { title: string; body?: string; cta?: { to: string; label: string }; action?: ReactNode }) => (
  <div className="py-8 text-center">
    <p className="font-semibold">{title}</p>
    {body && <p className="mt-1 text-sm text-mute">{body}</p>}
    {cta && <Link to={cta.to} className="mt-3 inline-flex min-h-11 items-center text-sm font-semibold text-accent underline">{cta.label}</Link>}
    {action}
  </div>
);
