import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../lib/api";
import { useMe } from "../lib/query";
import { useTheme, type ThemePref } from "../lib/theme";
import { Button, Card, CardTitle, Segmented } from "../components/ui";

const input = "min-h-11 w-full rounded-xl border border-line bg-well px-3 text-sm";

/** "Chrome on macOS"-style label from a user agent, without shipping a parser: good enough to recognise your own devices. */
export function deviceLabel(ua: string | null) {
  if (!ua) return "Unknown device";
  const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "Browser";
  const os = /iPhone|iPad/.test(ua) ? "iOS" : /Android/.test(ua) ? "Android" : /Mac OS X/.test(ua) ? "macOS" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "";
  return os ? `${browser} on ${os}` : browser;
}

function Sessions() {
  const qc = useQueryClient();
  const list = useQuery({ queryKey: ["sessions"], queryFn: api.sessions });
  const refresh = () => void qc.invalidateQueries({ queryKey: ["sessions"] });
  const revoke = useMutation({ mutationFn: (id: number) => api.revokeSession(id), onSuccess: refresh });
  const others = useMutation({ mutationFn: api.revokeOtherSessions, onSuccess: refresh });
  const rows = list.data?.sessions ?? [];
  return (
    <Card aria-labelledby="sessions-title">
      <CardTitle id="sessions-title">Where you are signed in</CardTitle>
      <ul className="mt-3 divide-y divide-line">
        {rows.map((s) => (
          <li key={s.id} className="flex items-center justify-between gap-3 py-3">
            <div className="min-w-0">
              <p className="m-0 truncate text-sm font-medium">{deviceLabel(s.user_agent)}{s.current && <span className="ml-2 rounded-full bg-well px-2 py-0.5 text-xs font-semibold">This device</span>}</p>
              <p className="m-0 text-xs text-mute">Last active {new Date(s.last_seen_at).toLocaleString()}</p>
            </div>
            {!s.current && <Button variant="secondary" disabled={revoke.isPending} aria-label={`Sign out ${deviceLabel(s.user_agent)}`} onClick={() => revoke.mutate(s.id)}>Sign out</Button>}
          </li>
        ))}
      </ul>
      {rows.length > 1 && <Button className="mt-3" variant="secondary" disabled={others.isPending} onClick={() => others.mutate()}>Sign out all other devices</Button>}
      {list.isError && <p role="alert" className="mt-2 text-sm text-loss">{(list.error as Error).message}</p>}
    </Card>
  );
}

function ChangePassword() {
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const m = useMutation({ mutationFn: () => api.changePassword({ current_password: current, password: next }), onSuccess: () => { setCurrent(""); setNext(""); } });
  return (
    <Card aria-labelledby="password-title">
      <CardTitle id="password-title">Change password</CardTitle>
      <form className="mt-3 space-y-3" onSubmit={(e) => { e.preventDefault(); m.mutate(); }}>
        <div><label htmlFor="current-password" className="mb-1 block text-sm font-semibold">Current password</label>
          <input id="current-password" type="password" autoComplete="current-password" className={input} value={current} onChange={(e) => setCurrent(e.target.value)} /></div>
        <div><label htmlFor="next-password" className="mb-1 block text-sm font-semibold">New password</label>
          <input id="next-password" type="password" autoComplete="new-password" className={input} value={next} onChange={(e) => setNext(e.target.value)} />
          <p className="mt-1 text-xs text-mute">At least 8 characters. Other devices are signed out when you change it.</p></div>
        <Button type="submit" disabled={m.isPending || !current || next.length < 8}>Change password</Button>
        {m.isSuccess && <p role="status" className="text-sm font-medium">Password changed. Other devices were signed out.</p>}
        {m.isError && <p role="alert" className="text-sm text-loss">{(m.error as Error).message}</p>}
      </form>
    </Card>
  );
}

function Notifications() {
  const { data: me } = useMe();
  const qc = useQueryClient();
  const m = useMutation({ mutationFn: api.preferences, onSuccess: (u) => qc.setQueryData(["me"], u) });
  const prefs = me?.preferences;
  if (!prefs) return null;
  const row = (key: "notify_order_filled" | "notify_order_rejected", label: string) => (
    <label className="flex min-h-11 items-center justify-between gap-3 text-sm">
      <span>{label}</span>
      <input type="checkbox" role="switch" checked={prefs[key]} disabled={m.isPending} onChange={(e) => m.mutate({ [key]: e.target.checked })} className="size-5" />
    </label>
  );
  return (
    <Card aria-labelledby="notify-title">
      <CardTitle id="notify-title">Email</CardTitle>
      <p className="mt-1 text-sm text-mute">Security emails (password changes, resets) are always sent. These are about orders that waited for the market to open.</p>
      <div className="mt-2">{row("notify_order_filled", "Email me when a waiting order is filled")}{row("notify_order_rejected", "Email me when a waiting order could not be filled")}</div>
      {m.isError && <p role="alert" className="mt-2 text-sm text-loss">{(m.error as Error).message}</p>}
    </Card>
  );
}

function YourData() {
  const m = useMutation({
    mutationFn: api.exportData,
    onSuccess: (data) => {
      const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: "application/json" }));
      const a = document.createElement("a");
      a.href = url; a.download = "paper-broker-export.json"; a.click();
      URL.revokeObjectURL(url);
    },
  });
  return (
    <Card aria-labelledby="data-title">
      <CardTitle id="data-title">Your data</CardTitle>
      <p className="mt-1 text-sm text-mute">Download your orders, deposits and positions as a JSON file.</p>
      <Button className="mt-3" variant="secondary" disabled={m.isPending} onClick={() => m.mutate()}>{m.isPending ? "Preparing…" : "Download my data"}</Button>
      {m.isError && <p role="alert" className="mt-2 text-sm text-loss">{(m.error as Error).message}</p>}
    </Card>
  );
}

function DeleteAccount() {
  const qc = useQueryClient();
  const [word, setWord] = useState("");
  const [password, setPassword] = useState("");
  const m = useMutation({ mutationFn: () => api.deleteAccount({ confirm: "DELETE", password }), onSuccess: () => { qc.clear(); window.location.assign("/welcome"); } });
  return (
    <Card aria-labelledby="delete-title">
      <CardTitle id="delete-title">Delete account</CardTitle>
      <p className="mt-1 text-sm text-mute">Removes your sign-in, watchlist and personal details. Practice orders stay in our records without your name. This can't be undone.</p>
      <form className="mt-3 space-y-3" onSubmit={(e) => { e.preventDefault(); m.mutate(); }}>
        <div><label htmlFor="delete-password" className="mb-1 block text-sm font-semibold">Your password</label>
          <input id="delete-password" type="password" autoComplete="current-password" className={input} value={password} onChange={(e) => setPassword(e.target.value)} /></div>
        <div><label htmlFor="delete-word" className="mb-1 block text-sm font-semibold">Type DELETE to confirm</label>
          <input id="delete-word" autoComplete="off" className={input} value={word} onChange={(e) => setWord(e.target.value)} /></div>
        <Button type="submit" variant="danger" disabled={m.isPending || word.trim() !== "DELETE" || !password}>Delete my account</Button>
        {m.isError && <p role="alert" className="text-sm text-loss">{(m.error as Error).message}</p>}
      </form>
    </Card>
  );
}

export default function Settings() {
  const { data: me } = useMe();
  const { pref, setPref } = useTheme();
  const qc = useQueryClient();
  const [confirm, setConfirm] = useState("");
  const [done, setDone] = useState(false);

  const reset = useMutation({
    mutationFn: api.reset,
    onSuccess: (u) => { qc.clear(); qc.setQueryData(["me"], u); void qc.invalidateQueries(); setConfirm(""); setDone(true); },
  });
  const logout = useMutation({ mutationFn: api.logout, onSuccess: () => { qc.clear(); window.location.assign("/welcome"); } });

  return (
    <div className="mx-auto max-w-xl space-y-5">
      <h1 className="m-0 text-[32px] font-semibold tracking-[-0.02em]">Settings</h1>
      <Card>
        <CardTitle>Profile</CardTitle>
        <p className="mt-1 text-sm">{me?.name}</p>
        <p className="text-sm text-mute">{me?.email}</p>
        {me && me.verified === false && <p className="mt-2 text-xs text-mute">Email not confirmed yet.</p>}
      </Card>
      <Sessions />
      <ChangePassword />
      <Notifications />
      <Card>
        <CardTitle>Appearance</CardTitle>
        <div className="mt-3"><Segmented<ThemePref> label="Appearance" role="radio" large value={pref} onChange={setPref}
          options={[{ value: "light", label: "Light" }, { value: "dark", label: "Dark" }, { value: "system", label: "Match device" }]} /></div>
      </Card>
      <Card>
        <CardTitle>Reset account</CardTitle>
        <p className="mt-1 text-sm text-mute">Deletes all positions, orders, deposits and history, and restores the $100,000 starting cash. This can't be undone.</p>
        <form className="mt-3 flex flex-wrap gap-2" onSubmit={(e) => { e.preventDefault(); reset.mutate(); }}>
          <label htmlFor="confirm" className="sr-only">Type RESET to confirm</label>
          <input id="confirm" value={confirm} onChange={(e) => setConfirm(e.target.value)} placeholder="Type RESET to confirm" autoComplete="off"
            className="min-h-11 flex-1 rounded-xl border border-line bg-well px-3 text-sm" />
          <Button type="submit" variant="danger" disabled={confirm.trim().toUpperCase() !== "RESET" || reset.isPending}>Reset account</Button>
        </form>
        {done && <p role="status" className="mt-2 text-sm font-medium">Account reset. You're back to your starting cash.</p>}
        {reset.isError && <p role="alert" className="mt-2 text-sm text-loss">{(reset.error as Error).message}</p>}
      </Card>
      <YourData />
      <DeleteAccount />
      <Button variant="secondary" onClick={() => logout.mutate()}>Sign out</Button>
    </div>
  );
}
