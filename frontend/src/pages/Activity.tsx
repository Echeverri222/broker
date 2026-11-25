import { useState } from "react";
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { api, type Order } from "../lib/api";
import { dateTime, money, price, qty } from "../lib/format";
import { Button, Card, Empty, ErrorBox, Skeleton } from "../components/ui";

const CHIP: Record<string, string> = {
  pending: "Waiting for the market to open", cancelled: "Cancelled", rejected: "Not filled",
};

function Detail({ o }: { o: Order }) {
  if (o.status === "filled") return <>{qty(o.quantity ?? "0")} @ {price(o.price ?? "0")} · {dateTime(o.filled_at ?? o.created_at)}</>;
  const what = o.sell_all ? "all shares" : o.amount ? money(o.amount) : `${qty(o.requested_quantity ?? "0")}`;
  return <>{what} · placed {dateTime(o.created_at)}</>;
}

export default function Activity() {
  const qc = useQueryClient();
  const cancel = useMutation({
    mutationFn: (id: number) => api.cancelOrder(id),
    onSuccess: () => ["orders", "portfolio", "me"].forEach((k) => qc.invalidateQueries({ queryKey: [k] })),
  });
  const [page, setPage] = useState(1);
  const [side, setSide] = useState("");
  const [symbol, setSymbol] = useState("");
  const { data, isLoading, isError, refetch } = useQuery({
    queryKey: ["orders", page, side, symbol], queryFn: () => api.orders({ page, side, symbol: symbol.trim() }), placeholderData: keepPreviousData,
  });
  const deposits = useQuery({ queryKey: ["deposits"], queryFn: api.deposits });
  const pages = data ? Math.max(1, Math.ceil(data.total / data.per_page)) : 1;
  const filter = "min-h-11 rounded-xl border border-line bg-card px-3 text-sm";

  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-bold">Activity</h1>
      <div className="flex flex-wrap gap-2">
        <label className="sr-only" htmlFor="side">Side</label>
        <select id="side" value={side} onChange={(e) => { setSide(e.target.value); setPage(1); }} className={filter}>
          <option value="">All orders</option><option value="buy">Buys</option><option value="sell">Sells</option>
        </select>
        <label className="sr-only" htmlFor="sym">Ticker</label>
        <input id="sym" placeholder="Ticker, e.g. AAPL" value={symbol} onChange={(e) => { setSymbol(e.target.value); setPage(1); }} className={filter} />
      </div>
      <Card className="!p-0 overflow-hidden">
        {isError ? <div className="p-4"><ErrorBox message="Couldn't load your orders." onRetry={() => refetch()} /></div>
          : isLoading ? <div className="space-y-3 p-4">{Array.from({ length: 5 }, (_, i) => <Skeleton key={i} className="h-12 w-full" />)}</div>
          : !data?.orders.length ? <Empty title="No orders yet" body="Every trade you make will be listed here." cta={{ to: "/markets", label: "Go to Markets" }} />
          : (
            <ul className="divide-y divide-line">
              {data.orders.map((o) => (
                <li key={o.id} className="flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-3">
                  <span className={`w-12 text-sm font-bold uppercase ${o.side === "buy" ? "text-gain" : "text-loss"}`}>{o.side === "buy" ? "▲ Buy" : "▼ Sell"}</span>
                  <div className="min-w-0 flex-1">
                    <Link to={`/assets/${o.symbol}`} className="font-semibold hover:underline">{o.symbol}</Link>
                    <p className="text-xs text-mute"><Detail o={o} /></p>
                    {o.status !== "filled" && (
                      <p className={`mt-1 inline-block rounded-full border border-line px-2 py-0.5 text-xs font-semibold ${o.status === "rejected" ? "text-loss" : "text-mute"}`}>{CHIP[o.status]}</p>
                    )}
                    {o.status === "rejected" && o.reject_reason && <p className="mt-1 text-xs text-mute">{o.reject_reason}</p>}
                  </div>
                  <div className="text-right">
                    {o.status === "filled" && <p className="font-semibold">{money(o.total ?? "0")}</p>}
                    {o.status === "pending" && (
                      <Button variant="secondary" disabled={cancel.isPending} onClick={() => cancel.mutate(o.id)} aria-label={`Cancel ${o.side} order for ${o.symbol}`}>Cancel</Button>
                    )}
                    {o.realized_pnl && <p className="text-xs text-mute">Realized {Number(o.realized_pnl) >= 0 ? "+" : "−"}{money(Math.abs(Number(o.realized_pnl)))}</p>}
                  </div>
                </li>
              ))}
            </ul>
          )}
      </Card>
      <h2 className="pt-2 text-lg font-bold">Deposits</h2>
      <Card className="!p-0 overflow-hidden">
        {deposits.isLoading ? <div className="p-4"><Skeleton className="h-12 w-full" /></div> : (
          <ul className="divide-y divide-line">
            {deposits.data?.deposits.map((d) => (
              <li key={d.id} className="flex items-center justify-between px-4 py-3">
                <div><p className="font-semibold">{d.kind === "initial" ? "Starting cash" : "Deposit"}</p><p className="text-xs text-mute">{dateTime(d.created_at)}</p></div>
                <p className="font-semibold text-gain">+{money(d.amount)}</p>
              </li>
            ))}
          </ul>
        )}
      </Card>
      {pages > 1 && (
        <div className="flex items-center justify-between">
          <Button variant="secondary" disabled={page <= 1} onClick={() => setPage(page - 1)}>Previous</Button>
          <span className="text-sm text-mute">Page {page} of {pages}</span>
          <Button variant="secondary" disabled={page >= pages} onClick={() => setPage(page + 1)}>Next</Button>
        </div>
      )}
    </div>
  );
}
