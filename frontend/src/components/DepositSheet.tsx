import { useEffect, useRef, useState } from "react";
import { useForm } from "react-hook-form";
import { z } from "zod";
import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api, type ApiError, type Deposit } from "../lib/api";
import { cleanNumber } from "../lib/input";
import { money, moneyWhole } from "../lib/format";
import { Button } from "./ui";

const schema = z.object({
  amount: z.string().trim().min(1, "Enter an amount")
    .refine((v) => /^\d+(\.\d{1,2})?$/.test(v), "Use dollars and cents, e.g. 250.00")
    .refine((v) => Number(v) >= 1, "Minimum deposit is $1.00")
    .refine((v) => Number(v) <= 10_000_000, "Maximum deposit is $10,000,000"),
});
type Form = z.infer<typeof schema>;
const PRESETS = ["1000", "5000", "10000", "50000"];
const newKey = () => (crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`);

/** Virtual deposit. No real money moves; deposits are tracked so returns exclude them. */
export function DepositSheet({ onClose }: { onClose: () => void }) {
  const qc = useQueryClient();
  const key = useRef(newKey());
  const [done, setDone] = useState<Deposit | null>(null);
  const { register, handleSubmit, setValue, setError, formState: { errors } } = useForm<Form>({ resolver: zodResolver(schema), defaultValues: { amount: "" } });

  useEffect(() => {
    const h = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, [onClose]);

  const m = useMutation({
    mutationFn: (f: Form) => api.deposit(f.amount, key.current),
    onSuccess: (d) => {
      setDone(d);
      ["me", "portfolio", "history", "deposits"].forEach((k) => qc.invalidateQueries({ queryKey: [k] }));
    },
    onError: (e: ApiError) => { setError("amount", { message: e.message }); key.current = newKey(); },
  });

  return (
    <div className="fixed inset-0 z-[60] flex items-end bg-scrim md:items-center md:justify-center" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div role="dialog" aria-modal="true" aria-label="Add cash" className="sheet w-full bg-card p-5 shadow-2xl md:w-[400px] rounded-t-md md:rounded-none">
        <div className="mb-3 flex items-start justify-between">
          <div>
            <h2 className="text-lg font-bold">{done ? "Cash added" : "Add virtual cash"}</h2>
            <p className="text-sm text-mute">No real money moves. Deposits don't count as investment gains.</p>
          </div>
          <button onClick={onClose} aria-label="Close" className="grid size-10 place-items-center text-xl hover:bg-well">×</button>
        </div>
        {done ? (
          <div aria-live="polite">
            <p className=" bg-bg p-3 text-sm">Deposited <strong>{money(done.amount)}</strong>. New cash balance: <strong>{money(done.cash ?? 0)}</strong>.</p>
            <Button className="mt-4 w-full" onClick={onClose}>Done</Button>
          </div>
        ) : (
          <form onSubmit={handleSubmit((f) => m.mutate(f))} noValidate>
            <div className="mb-3 grid grid-cols-4 gap-2">
              {PRESETS.map((p) => <Button key={p} type="button" variant="secondary" className="px-0" onClick={() => setValue("amount", p, { shouldValidate: true })}>{moneyWhole(p)}</Button>)}
            </div>
            <label htmlFor="deposit-amount" className="mb-1 block text-sm font-medium">Amount (USD)</label>
            <input id="deposit-amount" inputMode="decimal" autoFocus autoComplete="off" placeholder="0.00" aria-invalid={!!errors.amount}
              className="min-h-12 w-full border border-line bg-bg px-3 text-xl font-semibold rounded-md" {...register("amount", { setValueAs: cleanNumber })} />
            {errors.amount && <p role="alert" className="mt-1 text-sm text-loss">{errors.amount.message}</p>}
            <Button type="submit" className="mt-4 w-full" disabled={m.isPending}>{m.isPending ? "Adding…" : "Add cash"}</Button>
          </form>
        )}
      </div>
    </div>
  );
}
