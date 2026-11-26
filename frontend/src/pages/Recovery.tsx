import { useEffect, useRef, useState, type ReactNode } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api, ApiError } from "../lib/api";
import { Button, Card, CardTitle } from "../components/ui";

const field = "min-h-[52px] w-full rounded-[14px] border border-line bg-card px-4 text-base font-medium";

function Shell({ title, children }: { title: string; children: ReactNode }) {
  return (
    <main className="grid min-h-dvh place-items-center bg-bg p-6">
      <Card className="w-full max-w-[420px]">
        <CardTitle>{title}</CardTitle>
        <div className="mt-4 space-y-4">{children}</div>
        <p className="mt-6 text-sm text-mute"><Link to="/welcome" className="font-semibold text-accent underline">Back to sign in</Link></p>
      </Card>
    </main>
  );
}

/** SES-05: the answer is the same whether or not the email has an account, so the screen says so too. */
export function ForgotPassword() {
  const [email, setEmail] = useState("");
  const m = useMutation({ mutationFn: () => api.requestPasswordReset(email.trim()) });
  return (
    <Shell title="Reset your password">
      {m.isSuccess ? (
        <p role="status" className="text-sm">If there is an account for that email, we sent a link to reset the password. It works for 30 minutes.</p>
      ) : (
        <form className="space-y-4" onSubmit={(e) => { e.preventDefault(); m.mutate(); }}>
          <div><label htmlFor="email" className="mb-1.5 block text-sm font-semibold">Email</label>
            <input id="email" type="email" autoComplete="email" required className={field} value={email} onChange={(e) => setEmail(e.target.value)} /></div>
          {m.isError && <p role="alert" className="text-sm text-loss">{(m.error as Error).message}</p>}
          <Button type="submit" className="w-full" disabled={m.isPending || !email.trim()}>{m.isPending ? "Sending…" : "Send reset link"}</Button>
        </form>
      )}
    </Shell>
  );
}

/** SES-05: the token comes from the email link (?token=...). Success signs every device out, so go to sign in. */
export function ResetPassword() {
  const token = useSearchParams()[0].get("token") ?? "";
  const [password, setPassword] = useState("");
  const m = useMutation({ mutationFn: () => api.resetPassword({ token, password }) });
  const invalid = m.error instanceof ApiError && m.error.code === "invalid_token";
  return (
    <Shell title="Choose a new password">
      {m.isSuccess ? (
        <p role="status" className="text-sm">Your password was changed and every device was signed out. <Link to="/welcome" className="font-semibold text-accent underline">Sign in</Link> with the new one.</p>
      ) : !token ? (
        <p role="alert" className="text-sm text-loss">This link is missing its token. Open the link from the email again, or <Link to="/forgot-password" className="underline">ask for a new one</Link>.</p>
      ) : (
        <form className="space-y-4" onSubmit={(e) => { e.preventDefault(); m.mutate(); }}>
          <div><label htmlFor="new-password" className="mb-1.5 block text-sm font-semibold">New password</label>
            <input id="new-password" type="password" autoComplete="new-password" className={field} value={password} onChange={(e) => setPassword(e.target.value)} aria-describedby="pw-hint" />
            <p id="pw-hint" className="mt-1.5 text-[13px] text-mute">At least 8 characters.</p></div>
          {m.isError && (
            <p role="alert" className="text-sm text-loss">
              {invalid ? <>This link has expired or was already used. <Link to="/forgot-password" className="underline">Ask for a new one</Link>.</> : (m.error as Error).message}
            </p>
          )}
          <Button type="submit" className="w-full" disabled={m.isPending || password.length < 8}>{m.isPending ? "Saving…" : "Change password"}</Button>
        </form>
      )}
    </Shell>
  );
}

/** SES-07: opening the link in the email confirms the address. Runs once, even under React strict mode. */
export function VerifyEmail() {
  const token = useSearchParams()[0].get("token") ?? "";
  const qc = useQueryClient();
  const ran = useRef(false);
  const m = useMutation({ mutationFn: () => api.verifyEmail(token), onSuccess: () => void qc.invalidateQueries({ queryKey: ["me"] }) });
  useEffect(() => {
    if (ran.current || !token) return;
    ran.current = true;
    m.mutate();
  }, [token, m]);
  return (
    <Shell title="Confirm your email">
      {!token ? <p role="alert" className="text-sm text-loss">This link is missing its token. Open the link from the email again.</p>
        : m.isSuccess ? <p role="status" className="text-sm">Thanks, your email is confirmed. <Link to="/" className="font-semibold text-accent underline">Go to your dashboard</Link>.</p>
        : m.isError ? <p role="alert" className="text-sm text-loss">This link has expired or was already used. Sign in and use "Resend" in the banner to get a new one.</p>
        : <p role="status" className="text-sm text-mute">Confirming…</p>}
    </Shell>
  );
}
