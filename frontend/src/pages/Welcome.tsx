import { useState } from "react";
import { useForm } from "react-hook-form";
import { z } from "zod";
import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { api, ApiError } from "../lib/api";
import { Button, Logo } from "../components/ui";
import { LineChart as Mark } from "lucide-react";

const schema = z.object({
  name: z.string().trim().optional(),
  email: z.string().trim().email("Enter a valid email address"),
  password: z.string().min(8, "Use at least 8 characters"),
});
type Form = z.infer<typeof schema>;

export default function Welcome() {
  const [mode, setMode] = useState<"signup" | "login">("signup");
  const qc = useQueryClient();
  const nav = useNavigate();
  const from = (useLocation().state as { from?: string } | null)?.from ?? "/";
  const { register, handleSubmit, setError, formState: { errors } } = useForm<Form>({ resolver: zodResolver(schema) });
  const m = useMutation({
    mutationFn: (f: Form) => (mode === "signup" ? api.signup({ name: f.name || f.email.split("@")[0], email: f.email, password: f.password }) : api.login(f)),
    onSuccess: (u) => { qc.clear(); qc.setQueryData(["me"], u); nav(from, { replace: true }); },
    onError: (e: ApiError) => setError("root", { message: e.message }),
  });
  const field = "min-h-[52px] w-full rounded-[14px] border border-line bg-card px-4 text-base font-medium";

  return (
    <div className="flex min-h-dvh flex-wrap bg-bg">
      <div className="flex min-w-0 flex-[1_1_520px] flex-col justify-center gap-7 px-6 py-10 md:px-16 md:py-12">
        <div className="flex items-center gap-2.5">
          <span aria-hidden className="grid size-9 place-items-center rounded-[10px] bg-ink text-bg"><Mark size={20} strokeWidth={2.4} /></span>
          <span className="text-xl font-bold tracking-[-0.02em]">Paper</span>
        </div>
        <div>
          <h1 className="m-0 text-[40px] font-bold leading-[1.05] tracking-[-0.035em] md:text-[52px]">Practice investing with $100,000 of virtual cash.</h1>
          <p className="mt-4 max-w-[480px] text-lg leading-relaxed text-mute">Real prices. No real money. See how your decisions would have performed.</p>
        </div>
        <form onSubmit={handleSubmit((f) => m.mutate(f))} noValidate className="flex max-w-[400px] flex-col gap-3.5">
          {mode === "signup" && (
            <div><label htmlFor="name" className="mb-1.5 block text-sm font-semibold">Name <span className="font-normal text-mute">(optional)</span></label>
              <input id="name" autoComplete="name" className={field} {...register("name")} /></div>
          )}
          <div><label htmlFor="email" className="mb-1.5 block text-sm font-semibold">Email</label>
            <input id="email" type="email" autoComplete="email" className={field} aria-invalid={!!errors.email} {...register("email")} />
            {errors.email && <p role="alert" className="mt-1 text-sm text-loss">{errors.email.message}</p>}</div>
          <div><label htmlFor="password" className="mb-1.5 block text-sm font-semibold">Password</label>
            <input id="password" type="password" aria-describedby="pw-hint" autoComplete={mode === "signup" ? "new-password" : "current-password"} className={field} aria-invalid={!!errors.password} {...register("password")} />
            <p id="pw-hint" className="mt-1.5 text-[13px] text-mute">At least 8 characters.</p>
            {errors.password && <p role="alert" className="mt-1 text-sm text-loss">{errors.password.message}</p>}</div>
          {errors.root && <p role="alert" className="text-sm text-loss">{errors.root.message}</p>}
          <Button type="submit" className="min-h-[54px] w-full rounded-[14px] text-[17px]" disabled={m.isPending}>{m.isPending ? "One moment…" : mode === "signup" ? "Create account" : "Sign in"}</Button>
          {mode === "login" && <p className="m-0 text-sm"><Link to="/forgot-password" className="inline-flex min-h-11 items-center font-semibold text-accent underline">Forgot your password?</Link></p>}
          <p className="m-0 text-sm text-mute">{mode === "signup" ? "Already have an account? " : "New here? "}
            <button type="button" onClick={() => setMode(mode === "signup" ? "login" : "signup")} className="inline-flex min-h-11 items-center font-semibold text-accent underline">
              {mode === "signup" ? "Sign in" : "Create an account"}
            </button></p>
        </form>
      </div>

      <div className="grid min-h-[560px] min-w-0 flex-[1_1_520px] place-items-center bg-well p-6 md:p-12">
        <section aria-label="Example portfolio, for illustration only" className="w-[min(440px,100%)] rounded-[28px] border border-line bg-card p-7">
          <p className="m-0 text-xs font-semibold uppercase tracking-wide text-mute">Example only</p>
          <h2 className="m-0 mt-1 text-xl font-bold tracking-[-0.01em]">Your portfolio</h2>
          <p className="mt-2 text-[44px] font-bold leading-none tracking-[-0.035em]">$104,862<span className="cents">40</span></p>
          <p className="mt-2 text-[15px] font-semibold text-gain"><span aria-hidden>▲</span><span className="sr-only">Up </span> $1,284.10 (1.24%) <span className="font-medium text-mute">today</span></p>
          <svg viewBox="0 0 400 90" role="img" aria-label="Illustrative rising line" className="mt-4 h-[90px] w-full text-chart"><polyline points="0,70 40,62 80,66 120,48 160,52 200,38 240,44 280,26 320,30 360,14 400,18" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinejoin="round" strokeLinecap="round" /></svg>
          <ul className="mt-4">
            {[["AAPL", "Apple, Inc.", "12.4 shares", "$2,481.30", "1.8%"], ["MSFT", "Microsoft Corp.", "5.2 shares", "$2,354.55", "0.4%"]].map(([sym, n, sh, v, c]) => (
              <li key={sym} className="flex items-center gap-3.5 border-t border-line py-3.5">
                <Logo symbol={sym} size={48} />
                <div className="flex-1"><p className="m-0 font-medium">{n}</p><p className="m-0 text-sm text-mute">{sh}</p></div>
                <div className="text-right"><p className="m-0 font-semibold">{v}</p><p className="m-0 text-sm font-semibold text-gain"><span aria-hidden>▲</span><span className="sr-only">Up </span> {c}</p></div>
              </li>
            ))}
          </ul>
        </section>
      </div>
    </div>
  );
}
