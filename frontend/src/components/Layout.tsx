import { useEffect, useRef, useState } from "react";
import { Link, NavLink, Outlet, useLocation, useNavigate } from "react-router-dom";
import { Home, LineChart as MarketsIcon, ListOrdered, Moon, Search, Settings as Gear, Star, Sun, LogOut } from "lucide-react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { DepositSheet } from "./DepositSheet";
import { SymbolPicker } from "./SymbolPicker";
import { HIT } from "./ui";
import { Banners } from "./Banners";
import { Money } from "./Money";
import { api } from "../lib/api";
import { useMe, usePortfolio } from "../lib/query";
import { resolve, useTheme } from "../lib/theme";

const TABS = [
  { to: "/", label: "Home", Icon: Home, end: true },
  { to: "/markets", label: "Markets", Icon: MarketsIcon, end: false },
  { to: "/activity", label: "Activity", Icon: ListOrdered, end: false },
  { to: "/markets?show=watching", label: "Watchlist", Icon: Star, end: false },
] as const;

/** Watchlist is a filtered Markets view, so it is "current" only when that filter is on (and Markets only when it is not). */
function useCurrent() {
  const { pathname, search } = useLocation();
  const watching = pathname === "/markets" && new URLSearchParams(search).get("show") === "watching";
  return (to: string, end: boolean) => {
    if (to.startsWith("/markets?")) return watching;
    if (to === "/markets") return pathname === "/markets" && !watching;
    return end ? pathname === to : pathname.startsWith(to);
  };
}

export function Layout() {
  const { data: pf } = usePortfolio();
  const { data: me } = useMe();
  const nav = useNavigate();
  const qc = useQueryClient();
  const current = useCurrent();
  const { pref, setPref } = useTheme();
  const [depositing, setDepositing] = useState(false);
  const [picker, setPicker] = useState<"search" | "buy" | "sell" | null>(null);
  const [menu, setMenu] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const logout = useMutation({ mutationFn: api.logout, onSuccess: () => { qc.clear(); window.location.assign("/welcome"); } });

  useEffect(() => {
    const h = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); setPicker("search"); }
    };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, []);
  useEffect(() => {
    if (!menu) return;
    const h = (e: MouseEvent) => !menuRef.current?.contains(e.target as Node) && setMenu(false);
    const k = (e: KeyboardEvent) => e.key === "Escape" && setMenu(false);
    document.addEventListener("mousedown", h); document.addEventListener("keydown", k);
    return () => { document.removeEventListener("mousedown", h); document.removeEventListener("keydown", k); };
  }, [menu]);

  const initial = (me?.name?.[0] ?? me?.email?.[0] ?? "?").toUpperCase();
  const dark = resolve(pref) === "dark";

  return (
    <div className="min-h-dvh pb-[72px] md:pb-0">
      <a href="#main" className="sr-only focus:not-sr-only focus:absolute focus:left-3 focus:top-3 focus:z-50 focus:rounded-lg focus:bg-card focus:px-3 focus:py-2">Skip to content</a>
      <header className="sticky top-0 z-20 border-b border-line bg-bg/90 backdrop-blur">
        <div className="mx-auto flex h-16 max-w-[1200px] items-center gap-4 px-4 md:gap-6 md:px-8">
          <Link to="/" className="flex items-center gap-2 text-[17px] font-bold tracking-tight">
            <span aria-hidden className="grid size-8 place-items-center rounded-[10px] bg-accent text-accent-ink"><MarketsIcon size={18} strokeWidth={2.4} /></span>
            <span>Paper</span>
          </Link>
          <nav aria-label="Main" className="hidden items-center gap-1 md:flex">
            {TABS.map((t) => (
              <NavLink key={t.label} to={t.to} aria-current={current(t.to, t.end) ? "page" : undefined}
                className={`${HIT} inline-flex min-h-10 items-center rounded-full px-4 text-[15px] font-semibold ${current(t.to, t.end) ? "bg-well text-ink" : "text-mute hover:text-ink"}`}>{t.label}</NavLink>
            ))}
          </nav>
          <div className="ml-auto flex items-center gap-2 md:gap-3">
            <button type="button" onClick={() => setPicker("search")} aria-label="Search assets" className={`${HIT} hidden min-h-10 items-center gap-2 rounded-full border border-line bg-card px-4 text-sm text-mute hover:text-ink md:inline-flex`}>
              <Search size={16} aria-hidden /> Search <kbd className="rounded border border-line px-1.5 text-xs">⌘K</kbd>
            </button>
            <button type="button" onClick={() => setPicker("search")} aria-label="Search assets" className={`${HIT} grid size-11 place-items-center rounded-full border border-line md:hidden`}><Search size={18} aria-hidden /></button>
            <span className="hidden text-sm text-mute lg:block" title={pf && Number(pf.reserved_cash) > 0 ? "Part of your cash is set aside for orders waiting for the market to open" : undefined}>
              Cash <strong className="text-ink">{pf ? <Money value={pf.cash} /> : "–"}</strong>
            </span>
            <button type="button" onClick={() => setDepositing(true)} className={`${HIT} inline-flex min-h-10 items-center rounded-full bg-accent px-4 text-sm font-semibold text-accent-ink hover:opacity-90`}>Add cash</button>
            <div ref={menuRef} className="relative">
              <button type="button" aria-haspopup="menu" aria-expanded={menu} aria-label="Account menu" onClick={() => setMenu((v) => !v)}
                className={`${HIT} grid size-11 place-items-center rounded-full bg-logo text-sm font-bold`}>{initial}</button>
              {menu && (
                <div role="menu" aria-label="Account" className="absolute right-0 top-12 z-30 w-56 rounded-2xl border border-line bg-card p-1.5">
                  <p className="truncate px-3 py-2 text-xs text-mute">{me?.email}</p>
                  <button role="menuitem" type="button" onClick={() => setPref(dark ? "light" : "dark")} className="flex min-h-11 w-full items-center gap-3 rounded-xl px-3 text-sm font-semibold hover:bg-well">
                    {dark ? <Sun size={16} aria-hidden /> : <Moon size={16} aria-hidden />}{dark ? "Light theme" : "Dark theme"}
                  </button>
                  <button role="menuitem" type="button" onClick={() => { setMenu(false); nav("/settings"); }} className="flex min-h-11 w-full items-center gap-3 rounded-xl px-3 text-sm font-semibold hover:bg-well"><Gear size={16} aria-hidden />Settings</button>
                  <button role="menuitem" type="button" onClick={() => logout.mutate()} className="flex min-h-11 w-full items-center gap-3 rounded-xl px-3 text-sm font-semibold hover:bg-well"><LogOut size={16} aria-hidden />Sign out</button>
                </div>
              )}
            </div>
          </div>
        </div>
      </header>
      <Banners />
      <main id="main" className="mx-auto max-w-[1200px] px-4 py-6 md:px-8 md:py-8"><Outlet /></main>
      {depositing && <DepositSheet onClose={() => setDepositing(false)} />}
      {picker && <SymbolPicker mode={picker} onClose={() => setPicker(null)} onPick={(a) => { setPicker(null); nav(`/assets/${a.symbol}${picker === "search" ? "" : `?trade=${picker}`}`); }} />}
      <nav aria-label="Main" className="fixed inset-x-0 bottom-0 z-30 grid grid-cols-4 border-t border-line bg-card md:hidden">
        {TABS.map(({ to, label, Icon, end }) => (
          <NavLink key={label} to={to} aria-current={current(to, end) ? "page" : undefined}
            className={`flex min-h-14 flex-col items-center justify-center gap-0.5 text-[11px] font-semibold ${current(to, end) ? "text-ink" : "text-mute"}`}>
            <Icon size={20} aria-hidden />{label}
          </NavLink>
        ))}
      </nav>
    </div>
  );
}
