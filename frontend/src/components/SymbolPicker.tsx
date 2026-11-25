import { useEffect, useRef, useState } from "react";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { Search } from "lucide-react";
import { api, type AssetListItem } from "../lib/api";
import { price } from "../lib/format";
import { Delta, Logo } from "./ui";

export type PickMode = "search" | "buy" | "sell" | "compare";
const TITLE: Record<PickMode, string> = { search: "Search", buy: "Buy which asset?", sell: "Sell which holding?", compare: "Compare with" };

/** Modal search used by the nav (Cmd/Ctrl+K), the Buy and Sell pills, and Compare. Sell only lists what you own. */
export function SymbolPicker({ mode, onPick, onClose }: { mode: PickMode; onPick: (a: AssetListItem) => void; onClose: () => void }) {
  const [q, setQ] = useState("");
  const [dq, setDq] = useState("");
  const [active, setActive] = useState(0);
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => { const t = setTimeout(() => setDq(q), 150); return () => clearTimeout(t); }, [q]);
  useEffect(() => { input.current?.focus(); }, []);
  const { data } = useQuery({
    queryKey: ["picker", mode, dq], placeholderData: keepPreviousData,
    queryFn: () => api.assets({ q: dq, limit: 8, filter: mode === "sell" ? "owned" : undefined, sort: dq ? undefined : "volume" }),
  });
  const rows = data?.assets ?? [];
  useEffect(() => setActive(0), [dq]);

  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === "Escape") { e.preventDefault(); onClose(); }
    else if (e.key === "ArrowDown") { e.preventDefault(); setActive((i) => Math.min(rows.length - 1, i + 1)); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setActive((i) => Math.max(0, i - 1)); }
    else if (e.key === "Enter" && rows[active]) { e.preventDefault(); onPick(rows[active]); }
  };

  return (
    <div className="fixed inset-0 z-50 grid place-items-start justify-center bg-scrim px-4 pt-[12vh]" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div role="dialog" aria-modal="true" aria-label={TITLE[mode]} onKeyDown={onKey} className="w-full max-w-lg overflow-hidden rounded-[24px] border border-line bg-card">
        <div className="flex items-center gap-3 border-b border-line px-4">
          <Search size={18} className="text-mute" aria-hidden />
          <label htmlFor="picker-q" className="sr-only">{TITLE[mode]}</label>
          <input id="picker-q" ref={input} value={q} onChange={(e) => setQ(e.target.value)} placeholder={`${TITLE[mode]}: name or ticker`} autoComplete="off"
            role="combobox" aria-expanded aria-controls="picker-list" aria-activedescendant={rows[active] ? `pick-${rows[active].symbol}` : undefined}
            className="min-h-14 w-full bg-transparent text-base outline-none" />
          <kbd className="rounded-md border border-line px-1.5 py-0.5 text-xs text-mute">Esc</kbd>
        </div>
        <ul id="picker-list" role="listbox" aria-label="Results" className="max-h-[50vh] overflow-y-auto p-2">
          {rows.map((a, i) => (
            <li key={a.symbol} id={`pick-${a.symbol}`} role="option" aria-selected={i === active}>
              <button type="button" tabIndex={-1} onClick={() => onPick(a)} onMouseEnter={() => setActive(i)}
                className={`flex min-h-14 w-full items-center gap-3 rounded-xl px-3 text-left ${i === active ? "bg-well" : ""}`}>
                <Logo symbol={a.symbol} logoUrl={a.logo_url} size={36} />
                <span className="min-w-0 flex-1"><span className="block font-semibold">{a.symbol}</span><span className="block truncate text-xs text-mute">{a.name}</span></span>
                {a.quote && <span className="text-right"><span className="num block text-sm font-semibold">{price(a.quote.price)}</span><Delta percent={a.quote.change_percent} className="text-xs" /></span>}
              </button>
            </li>
          ))}
          {rows.length === 0 && <li className="p-6 text-center text-sm text-mute">{mode === "sell" ? "You don't own anything to sell yet." : "Nothing matches that search."}</li>}
        </ul>
      </div>
    </div>
  );
}
