import { useMutation } from "@tanstack/react-query";
import { api } from "../lib/api";
import { useMe } from "../lib/query";

/** SES-07 and ADM-05: two thin notices under the header. Neither blocks the app. */
export function Banners() {
  const { data: me } = useMe();
  const resend = useMutation({ mutationFn: api.resendVerification });
  if (!me) return null;
  return (
    <>
      {me.trading_enabled === false && (
        <div role="status" className="border-b border-line bg-well px-4 py-2.5 text-center text-sm font-medium">
          Trading is paused for maintenance. Your cash and positions are safe. You can still look around and cancel waiting orders.
        </div>
      )}
      {me.verified === false && (
        <div role="status" className="flex flex-wrap items-center justify-center gap-x-3 border-b border-line bg-well px-4 py-2.5 text-sm">
          <span>Confirm your email to keep your account recoverable. We sent a link to <strong>{me.email}</strong>.</span>
          {resend.isSuccess
            ? <span className="font-semibold">Sent. Check your inbox.</span>
            : <button type="button" onClick={() => resend.mutate()} disabled={resend.isPending} className="inline-flex min-h-11 items-center font-semibold text-accent underline disabled:opacity-50">
                {resend.isPending ? "Sending…" : "Resend"}
              </button>}
          {resend.isError && <span role="alert" className="text-loss">{(resend.error as Error).message}</span>}
        </div>
      )}
    </>
  );
}
