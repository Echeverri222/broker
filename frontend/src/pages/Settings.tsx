import { useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "../lib/api";
import { useMe } from "../lib/query";
import { useTheme, type ThemePref } from "../lib/theme";
import { Button, Card, CardTitle, Segmented } from "../components/ui";

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
        <p className="mt-2 text-xs text-mute">Passwords need at least 8 characters. Longer is stronger.</p>
      </Card>
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
      <Button variant="secondary" onClick={() => logout.mutate()}>Sign out</Button>
    </div>
  );
}
