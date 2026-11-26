import { useEffect, useRef, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { keepPreviousData, useInfiniteQuery, useMutation, useQueryClient, type InfiniteData } from "@tanstack/react-query";
import { Search, Star } from "lucide-react";
import { api, type AssetList, type AssetListItem } from "../lib/api";

import { pollInterval } from "../lib/query";
import { Button, Delta, Empty, ErrorBox, FilterChip, HIT, Logo, RangeBar, Skeleton, Sparkline } from "../components/ui";
import { Money } from "../components/Money";

export const SHOW = [["all", "All"], ["stock", "Stocks"], ["crypto", "Crypto"], ["etf", "ETFs"], ["watching", "Watching"], ["owned", "You own"]] as const;
export const PICKS = [["gainers", "Top gainers"], ["losers", "Top losers"], ["most_traded", "Most traded"], ["near_high", "Near 52-week high"], ["under_50", "Under $50"], ["open", "Open now"]] as const;
export const SORTS = [["change", "Biggest move today"], ["price_asc", "Price: low to high"], ["price_desc", "Price: high to low"], ["name", "Name A to Z"], ["volume", "Most traded"], ["change_1m", "Biggest 1-month move"]] as const;
const PAGE = 25;
const cols = "md:grid-cols-[minmax(0,2.2fr)_110px_110px_150px_110px_44px]";

/** FLT-08: every filter lives in the query string, so the view is shareable and back/forward works. */
export function readFilters(sp: URLSearchParams) {
  const show = SHOW.some(([k]) => k === sp.get("show")) ? sp.get("show")! : "all";
  const picks = (sp.get("pick") ?? "").split(",").filter((p) => PICKS.some(([k]) => k === p));
  const sort = SORTS.some(([k]) => k === sp.get("sort")) ? sp.get("sort")! : "change";
  return { q: sp.get("q") ?? "", show, picks, sort, sector: sp.get("sector") ?? "" };
}

export default function Markets() {
  const [sp, setSp] = useSearchParams();
  const f = readFilters(sp);
  const [text, setText] = useState(f.q);
  const [dq, setDq] = useState(f.q);
  const input = useRef<HTMLInputElement>(null);
  const qc = useQueryClient();

  const patch = (changes: Record<string, string | null>, replace = false) => {
    const n = new URLSearchParams(sp);
    for (const [k, v] of Object.entries(changes)) { if (v === null || v === "" || (k === "show" && v === "all") || (k === "sort" && v === "change")) n.delete(k); else n.set(k, v); }
    setSp(n, { replace });
  };
  // FLT-01: 200ms debounce, query mirrored into the URL.
  useEffect(() => { const t = setTimeout(() => setDq(text), 200); return () => clearTimeout(t); }, [text]);
  useEffect(() => { if (dq !== f.q) patch({ q: dq }, true); }, [dq]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { setText(f.q); setDq(f.q); }, [f.q]); // back/forward
  useEffect(() => {
    const h = (e: KeyboardEvent) => {
      const typing = e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement || e.target instanceof HTMLSelectElement;
      if (e.key === "/" && !typing) { e.preventDefault(); input.current?.focus(); }
    };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, []);

  // Home's "Watch" pill lands here with the search focused.
  useEffect(() => { if (sp.get("focus")) { input.current?.focus(); patch({ focus: null }, true); } }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const kind = ["stock", "etf", "crypto"].includes(f.show) ? f.show : undefined;
  const filter = [...(f.show === "watching" || f.show === "owned" ? [f.show] : []), ...f.picks].join(",") || undefined;
  const key = ["assets", f.q, kind, filter, f.sort, f.sector] as const;
  const list = useInfiniteQuery({
    queryKey: key, initialPageParam: 1, placeholderData: keepPreviousData, refetchInterval: () => pollInterval(),
    queryFn: ({ pageParam }) => api.assets({ q: f.q, kind, filter, sort: f.sort, sector: f.sector, page: pageParam, limit: PAGE }),
    getNextPageParam: (last, all) => (all.length * PAGE < last.meta.total ? all.length + 1 : undefined),
  });
  const rows = list.data?.pages.flatMap((p) => p.assets) ?? [];
  const meta = list.data?.pages[0]?.meta;
  const total = list.data?.pages.at(-1)?.meta.total ?? 0;

  // FLT-06: star toggles in place, optimistically.
  const star = useMutation({
    mutationFn: async (a: AssetListItem) => { await (a.watched ? api.unwatch(a.symbol) : api.watch(a.symbol)); },
    onMutate: async (a) => {
      await qc.cancelQueries({ queryKey: ["assets"] });
      const prev = qc.getQueriesData<InfiniteData<AssetList>>({ queryKey: ["assets"] });
      qc.setQueriesData<InfiniteData<AssetList>>({ queryKey: ["assets"] }, (d) => d && ({ ...d, pages: d.pages.map((p) => ({ ...p, assets: p.assets.map((x) => (x.symbol === a.symbol ? { ...x, watched: !a.watched } : x)) })) }));
      return { prev };
    },
    onError: (_e, _a, ctx) => ctx?.prev.forEach(([k, d]) => qc.setQueryData(k, d)),
    onSettled: () => { void qc.invalidateQueries({ queryKey: ["assets"] }); void qc.invalidateQueries({ queryKey: ["watchlist"] }); },
  });

  const filtered = f.show !== "all" || f.picks.length > 0 || f.sector !== "" || f.sort !== "change";
  const clear = () => { setText(""); setDq(""); setSp(new URLSearchParams()); };
  const togglePick = (p: string) => patch({ pick: (f.picks.includes(p) ? f.picks.filter((x) => x !== p) : [...f.picks, p]).join(",") });
  const count = (k: string) => (meta ? (meta.counts as Record<string, number>)[k === "etf" ? "etf" : k] : undefined);

  return (
    <div className="space-y-5">
      <h1 className="m-0 text-[32px] font-semibold tracking-[-0.02em]">Markets</h1>

      <div className="relative">
        <Search size={18} aria-hidden className="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-mute" />
        <label htmlFor="search" className="sr-only">Search assets</label>
        <input id="search" ref={input} type="search" value={text} onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Escape" && text) { e.preventDefault(); setText(""); } }}
          placeholder="Search by name or ticker  ( / )" className="min-h-12 w-full rounded-full border border-line bg-card pl-11 pr-4" />
      </div>

      <div role="radiogroup" aria-label="Show" className="flex gap-2 overflow-x-auto pb-1">
        {SHOW.map(([k, label]) => <FilterChip key={k} role="radio" on={f.show === k} onClick={() => patch({ show: k })} count={count(k)}>{label}</FilterChip>)}
      </div>
      <div role="group" aria-label="Quick picks" className="flex flex-wrap items-center gap-2">
        {PICKS.map(([k, label]) => <FilterChip key={k} on={f.picks.includes(k)} onClick={() => togglePick(k)}>{label}</FilterChip>)}
        {filtered && <button type="button" onClick={clear} className={`${HIT} min-h-10 px-2 text-sm font-semibold text-accent underline`}>Clear filters</button>}
      </div>
      <div className="flex flex-wrap items-center gap-3">
        <label className="flex items-center gap-2 text-sm text-mute">Sort
          <select value={f.sort} onChange={(e) => patch({ sort: e.target.value })} className="min-h-11 rounded-xl border border-line bg-card px-3 text-sm font-semibold text-ink">
            {SORTS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
          </select>
        </label>
        <label className="flex items-center gap-2 text-sm text-mute">Sector
          <select value={f.sector} onChange={(e) => patch({ sector: e.target.value })} className="min-h-11 rounded-xl border border-line bg-card px-3 text-sm font-semibold text-ink">
            <option value="">All sectors</option>
            {(meta?.sectors ?? []).map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
        </label>
        {meta && <p className="ml-auto text-sm text-mute" aria-live="polite">Showing {rows.length} of {total}</p>}
      </div>
      {meta?.fuzzy && rows[0] && <p role="status" className="text-sm text-mute">Showing results for <strong className="text-ink">{rows[0].name}</strong></p>}

      <div className="rounded-[24px] border border-line bg-card">
        {list.isError ? <div className="p-4"><ErrorBox message="Couldn't load markets." onRetry={() => list.refetch()} /></div>
          : list.isLoading ? <div className="space-y-3 p-4">{Array.from({ length: 8 }, (_, i) => <Skeleton key={i} className="h-14 w-full" />)}</div>
          : rows.length === 0 ? <Empty title="Nothing matches. Try fewer filters." action={<Button className="mt-3" variant="secondary" onClick={clear}>Clear filters</Button>} />
          : (
            <>
              <div aria-hidden="true" className={`sticky top-16 z-10 hidden gap-4 rounded-t-[24px] border-b border-line bg-card px-5 py-3 text-xs font-semibold text-mute md:grid ${cols}`}>
                <span>Name</span><span className="text-right">Price</span><span className="text-right">Today</span><span>52-week range</span><span>Last month</span><span className="sr-only">Watch</span>
              </div>
              <ul className="divide-y divide-line">
                {rows.map((a) => {
                  return (
                    <li key={a.symbol} className={`lift relative grid items-center gap-x-4 gap-y-1 px-4 py-3 md:gap-4 md:px-5 grid-cols-[minmax(0,1fr)_auto_44px] ${cols}`}>
                      <div className="flex min-w-0 items-center gap-3">
                        <Logo symbol={a.symbol} logoUrl={a.logo_url} size={40} />
                        <div className="min-w-0">
                          <Link to={`/assets/${a.symbol}`} className="font-semibold after:absolute after:inset-0 after:content-['']">{a.name}</Link>
                          <p className="truncate text-xs text-mute">{a.symbol} · <span className="capitalize">{a.kind}</span>{a.sector && a.sector !== "Crypto" ? ` · ${a.sector}` : ""}</p>
                        </div>
                      </div>
                      <div className="text-right md:hidden">
                        <p className="font-semibold">{a.quote ? <Money value={a.quote.price} asPrice /> : "–"}</p>
                        {a.change_percent !== null && <Delta percent={a.change_percent} className="text-xs" />}
                      </div>
                      <span className="hidden text-right font-semibold md:block">{a.quote ? <Money value={a.quote.price} asPrice /> : "–"}</span>
                      <span className="hidden text-right md:block">{a.change_percent !== null ? <Delta percent={a.change_percent} /> : "–"}</span>
                      <div className="hidden md:block"><RangeBar position={a.week52_position === null ? null : Number(a.week52_position)} label={`${a.symbol} 52-week range`} /></div>
                      <div className="hidden md:block"><Sparkline data={a.spark} /></div>
                      <button type="button" aria-pressed={a.watched} aria-label={`${a.watched ? "Stop watching" : "Watch"} ${a.symbol}`} onClick={() => star.mutate(a)}
                        className={`${HIT} relative z-10 grid size-11 place-items-center rounded-full hover:bg-well`}>
                        <Star size={18} aria-hidden fill={a.watched ? "currentColor" : "none"} className={a.watched ? "text-amber" : "text-mute"} />
                      </button>
                      <div className="col-span-3 flex items-center justify-end md:hidden"><Sparkline data={a.spark} width={90} height={24} /></div>
                    </li>
                  );
                })}
              </ul>
              {list.hasNextPage && (
                <div className="border-t border-line p-4 text-center">
                  <Button variant="secondary" pill onClick={() => list.fetchNextPage()} disabled={list.isFetchingNextPage}>{list.isFetchingNextPage ? "Loading…" : "Show more"}</Button>
                </div>
              )}
            </>
          )}
      </div>
    </div>
  );
}


