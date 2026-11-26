import { useEffect, useMemo, useRef, useState } from "react";
import { useForm } from "react-hook-form";
import { z } from "zod";
import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { api, ApiError, type AssetDetail, type OrderResponse } from "../lib/api";
import { cleanNumber, makeKeyStore, validateTradeInput } from "../lib/input";
import { formatOpen, money, price, qty } from "../lib/format";
import { useMarket, usePortfolio } from "../lib/query";
import { Button, HIT } from "./ui";
import { DepositSheet } from "./DepositSheet";

const schema = z.object({ value: z.string() });
type Form = z.infer<typeof schema>;
const newKey = () => (crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`);

/** Monday, Tuesday... of the next open in New York, for the queued-order button (CHT-15). */
const openDay = (iso?: string | null) => (iso ? new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", weekday: "long" }).format(new Date(iso)) : null);

/** CHT-15: `inline` is the sticky desktop panel; otherwise it is the bottom sheet used on phones. */
export function TradeSheet({ asset, initialSide, onClose, inline = false }: { asset: AssetDetail; initialSide: "buy" | "sell"; onClose: () => void; inline?: boolean }) {
  const qc = useQueryClient();
  const { data: pf } = usePortfolio();
  const market = useMarket();
  // QUE-01: a stock ordered while the market is closed waits for the open.
  const queued = asset.kind !== "crypto" && !!market.data && !market.data.open;
  const [side, setSide] = useState(initialSide);
  const [mode, setMode] = useState<"amount" | "quantity">("amount");
  const [step, setStep] = useState<"edit" | "review" | "receipt">("edit");
  const [receipt, setReceipt] = useState<OrderResponse | null>(null);
  const [sellAll, setSellAll] = useState(false);
  const [error, setError] = useState<ApiError | null>(null);
  const [depositing, setDepositing] = useState(false);
  const keys = useRef(makeKeyStore(newKey));
  const ref = useRef<HTMLDivElement>(null);
  const { register, handleSubmit, watch, setValue, reset, setError: setFieldError, formState: { errors } } = useForm<Form>({ resolver: zodResolver(schema), defaultValues: { value: "" } });

  const px = Number(asset.quote?.price ?? 0);
  const cash = Number(pf?.cash ?? 0) - Number(pf?.reserved_cash ?? 0); // QUE-04: reserved cash is not spendable
  const rawValue = String(watch("value") ?? "");
  const liveError = rawValue.trim() && !sellAll ? validateTradeInput(rawValue, mode) : null;
  const value = liveError ? 0 : Number(rawValue || 0) || 0;
  const est = useMemo(() => (mode === "amount" ? { total: value, quantity: px ? value / px : 0 } : { total: value * px, quantity: value }), [mode, value, px]);

  useEffect(() => { if (!inline) ref.current?.querySelector<HTMLInputElement>("input[name=value]")?.focus(); }, [step === "edit"]);
  useEffect(() => {
    if (inline) return;
    const h = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, [onClose, inline]);

  const place = useMutation({
    // UX-02: the key only changes when side/mode/value/sell-all change, so retries and double clicks reuse it.
    mutationFn: () => {
      const v = String(watch("value")).trim();
      const body = sellAll ? ({ symbol: asset.symbol, side, sell_all: true } as const) : { symbol: asset.symbol, side, [mode]: v };
      return api.placeOrder(body, keys.current.keyFor({ symbol: asset.symbol, side, mode, v, sellAll }));
    },
    onSuccess: (o) => {
      setReceipt(o); setStep("receipt"); setError(null);
      ["me", "portfolio", "orders", "asset", "history", "watchlist"].forEach((k) => qc.invalidateQueries({ queryKey: [k] }));
    },
    onError: (e) => { setError(e as ApiError); setStep("edit"); },
  });

  const setMax = () => {
    if (side === "buy") setValue("value", mode === "amount" ? cash.toFixed(2) : px ? String(Math.floor((cash / px) * 1e8) / 1e8) : "");
    else { setMode("quantity"); setValue("value", asset.position?.quantity ?? ""); setSellAll(true); } // ORD-05: explicit sell all
  };
  const chip = (v: string) => { setMode("amount"); setSellAll(false); setError(null); setValue("value", v); };
  const useSuggested = (v: string) => { setMode("amount"); setSellAll(false); setValue("value", v); setError(null); };

  const switchMode = () => { setMode(mode === "amount" ? "quantity" : "amount"); reset({ value: "" }); setSellAll(false); setError(null); };
  const available = side === "buy" ? `${money(cash)} cash available` : `${qty(asset.position?.quantity ?? "0")} ${asset.symbol} held`;

  const wrap = (children: React.ReactNode) => inline ? (
    <div ref={ref} role="region" aria-label={`Trade ${asset.symbol}`} className=" border border-line bg-card p-5 rounded-md">{children}</div>
  ) : (
    <div className="fixed inset-0 z-50 flex items-end bg-scrim md:items-stretch md:justify-end" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div ref={ref} role="dialog" aria-modal="true" aria-label={`Trade ${asset.symbol}`}
        className="sheet min-h-[78dvh] max-h-[92dvh] w-full overflow-y-auto rounded-t-md bg-card p-5 md:min-h-0 md:max-h-none md:w-[400px] md:rounded-none md:border-l md:border-line">{children}</div>
      {depositing && <DepositSheet onClose={() => { setDepositing(false); setError(null); }} />}
    </div>
  );
  const day = openDay(market.data?.next_open);
  const primary = queued ? `${side === "buy" ? "Buy" : "Sell"} at the open${day ? ` on ${day}` : ""}` : side === "buy" ? "Buy" : "Sell";

  return wrap(
    <>
        <div className="mb-4 flex items-start justify-between">
          <div>
            <h2 className="text-lg font-bold">{step === "receipt" ? (receipt?.order.status === "pending" ? "Order queued" : "Order filled") : `${side === "buy" ? "Buy" : "Sell"} ${asset.symbol}`}</h2>
            <p className="text-sm text-mute">{asset.name} · {asset.quote ? price(asset.quote.price) : "no price"}</p>
          </div>
          {!inline && <button onClick={onClose} aria-label="Close" className="grid size-11 place-items-center text-xl hover:bg-well">×</button>}
        </div>

        {step === "receipt" && receipt?.order.status === "pending" ? (
          <div aria-live="polite">
            <dl className="divide-y divide-line border border-line text-sm rounded-md">
              {[["Side", receipt.order.side === "buy" ? "Buy (waiting)" : "Sell (waiting)"],
                ["Order", receipt.order.sell_all ? `All ${asset.symbol}` : receipt.order.amount ? money(receipt.order.amount) : `${qty(receipt.order.requested_quantity ?? "0")} ${asset.symbol}`],
                ["Will be placed", market.data?.next_open ? formatOpen(market.data.next_open).replace("Market opens ", "").replace(/ \(in .*\)/, "") : "At the next market open"],
                ...(Number(receipt.order.reserved_cash) > 0 ? [["Cash held for this order", money(receipt.order.reserved_cash)]] : [])].map(([k, v]) => (
                <div key={k} className="flex justify-between px-3 py-2.5"><dt className="text-mute">{k}</dt><dd className="font-semibold">{v}</dd></div>
              ))}
            </dl>
            <p className="mt-2 text-[13px] text-mute">Nothing has been bought or sold yet. It fills at the first price after the market opens, and you can cancel it in Activity until then. Virtual money.</p>
            <div className="mt-4 grid grid-cols-2 gap-2">
              <Button variant="secondary" onClick={onClose}>Done</Button>
              <Link to="/activity" onClick={onClose} className="inline-flex min-h-11 items-center justify-center bg-accent text-sm font-semibold text-accent-ink rounded-md">View in Activity</Link>
            </div>
          </div>
        ) : step === "receipt" && receipt ? (
          <div aria-live="polite">
            <dl className="divide-y divide-line border border-line text-sm rounded-md">
              {[["Side", receipt.order.side === "buy" ? "Bought" : "Sold"], ["Quantity", `${qty(receipt.order.quantity ?? "0")} ${receipt.order.symbol}`], ["Price", price(receipt.order.price ?? "0")], ["Total", money(receipt.order.total ?? "0")], ...(receipt.order.realized_pnl ? [["Realized P&L", money(receipt.order.realized_pnl)]] : []), ["New cash balance", money(receipt.cash)]].map(([k, v]) => (
                <div key={k} className="flex justify-between px-3 py-2.5"><dt className="text-mute">{k}</dt><dd className="font-semibold">{v}</dd></div>
              ))}
            </dl>
            <p className="mt-2 text-[13px] text-mute">Simulated fill at last price. Virtual money.</p>
            <div className="mt-4 grid grid-cols-2 gap-2">
              <Button variant="secondary" onClick={onClose}>Done</Button>
              <Link to="/" onClick={onClose} className="inline-flex min-h-11 items-center justify-center bg-accent text-sm font-semibold text-accent-ink rounded-md">View position</Link>
            </div>
          </div>
        ) : (
          <form onSubmit={handleSubmit((f) => {
            if (step === "review") return place.mutate();
            const msg = sellAll ? null : validateTradeInput(f.value, mode);
            if (msg) return setFieldError("value", { message: msg });
            setStep("review");
          })} noValidate>
            <div role="tablist" aria-label="Order side" className="mb-4 grid grid-cols-2 border border-line p-0.5 rounded-md">
              {(["buy", "sell"] as const).map((s) => (
                <button type="button" key={s} role="tab" aria-selected={side === s} disabled={step === "review"} onClick={() => { setSide(s); setError(null); }}
                  className={`min-h-10 text-sm font-semibold capitalize ${side === s ? "bg-accent text-accent-ink" : "text-mute"}`}>{s}</button>
              ))}
            </div>

            <div className="mb-1 flex items-center justify-between text-sm font-medium">
              <label htmlFor="trade-value">{mode === "amount" ? "Amount (USD)" : `Quantity (${asset.symbol})`}</label>
              <button type="button" onClick={switchMode} disabled={step === "review"} className="text-[13px] font-semibold text-accent underline">
                Switch to {mode === "amount" ? "quantity" : "dollars"}
              </button>
            </div>
            <div className="flex gap-2">
              <input id="trade-value" inputMode="decimal" autoComplete="off" placeholder={mode === "amount" ? "0.00" : "0"} readOnly={step === "review"}
                aria-invalid={!!errors.value || !!error} aria-describedby="trade-help"
                className="min-h-12 w-full border border-line bg-well px-3 text-xl font-semibold rounded-md" {...register("value", { setValueAs: cleanNumber, onChange: () => setSellAll(false) })} />
              <Button type="button" variant="secondary" onClick={setMax} disabled={step === "review"}>Max</Button>
            </div>
            <p id="trade-help" className="mt-1.5 text-[13px] text-mute">{available}</p>
            {(errors.value?.message ?? liveError) && <p role="alert" className="mt-1 text-sm text-loss">{errors.value?.message ?? liveError}</p>}
            {side === "buy" && step === "edit" && (
              <div className="mt-2 flex flex-wrap gap-2" role="group" aria-label="Quick amounts">
                {["100", "500", "1000"].map((v) => (
                  <button key={v} type="button" onClick={() => chip(v)} className={`${HIT} min-h-9 rounded-md border border-line px-3 text-[13px] font-semibold hover:bg-well`}>{money(v).replace(".00", "")}</button>
                ))}
                <button type="button" onClick={() => chip(Math.max(0, cash).toFixed(2))} className={`${HIT} min-h-9 rounded-md border border-line px-3 text-[13px] font-semibold hover:bg-well`}>All cash</button>
              </div>
            )}

            {error && (
              <div role="alert" className="mt-3 border border-line p-3 text-sm rounded-md">
                <p className="font-medium text-loss">{error.message}</p>
                {error.code === "insufficient_funds" && error.details.max_amount && Number(error.details.max_amount) >= 1 && (
                  <button type="button" onClick={() => useSuggested(error.details.max_amount)} className="mt-1 font-semibold text-accent underline">
                    Use maximum {money(error.details.max_amount)}
                  </button>
                )}
                {error.code === "insufficient_funds" && (
                  <button type="button" onClick={() => setDepositing(true)} className="ml-3 mt-1 font-semibold text-accent underline">Add cash</button>
                )}
                {error.code === "insufficient_quantity" && error.details.max_quantity && (
                  <button type="button" onClick={() => { setMode("quantity"); setValue("value", error.details.max_quantity); setSellAll(true); setError(null); }} className="mt-1 font-semibold text-accent underline">
                    Sell all {qty(error.details.max_quantity)}
                  </button>
                )}
              </div>
            )}

            <dl className="mt-4 space-y-1.5 bg-well p-3 text-sm">
              <div className="flex justify-between"><dt className="text-mute">You'll get about</dt><dd>{sellAll ? qty(asset.position?.quantity ?? "0") : qty(est.quantity.toFixed(8))} {asset.symbol}</dd></div>
              <div className="flex justify-between"><dt className="text-mute">Estimated total</dt><dd className="font-semibold">{money(est.total)}</dd></div>
              {side === "buy" && queued && <div className="flex justify-between"><dt className="text-mute">Cash held for this order</dt><dd>{money(est.total)}</dd></div>}
              <div className="flex justify-between"><dt className="text-mute">Fees</dt><dd>$0.00</dd></div>
            </dl>

            {step === "review" ? (
              <div className="mt-4 grid grid-cols-[1fr_2fr] gap-2">
                <Button type="button" variant="secondary" onClick={() => setStep("edit")} disabled={place.isPending}>Edit</Button>
                <Button type="submit" disabled={place.isPending}>{place.isPending ? "Placing…" : queued ? `${side === "buy" ? "Buy" : "Sell"} at the open` : `Confirm ${side}`}</Button>
              </div>
            ) : (
              <Button type="submit" className="mt-4 w-full">{primary}</Button>
            )}
            <p className="mt-3 text-center text-[13px] text-mute">
              {queued
                ? `The market is closed, so this order will be queued${market.data?.next_open ? ` and placed at the open (${formatOpen(market.data.next_open).replace("Market opens ", "").replace(/ \(in .*\)/, "")})` : ""}. It fills at the first price after the open, which may differ from the one shown. Buys set cash aside until then. Virtual money.`
                : "Market order: fills right away at the latest price, which may differ slightly from the one shown. Virtual money."}
            </p>
          </form>
        )}
    {inline && depositing && <DepositSheet onClose={() => { setDepositing(false); setError(null); }} />}
    </>,
  );
}
