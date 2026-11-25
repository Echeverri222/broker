import { useCallback, useEffect, useSyncExternalStore } from "react";

export type ThemePref = "system" | "light" | "dark";
export const THEME_KEY = "pb_theme";
const listeners = new Set<() => void>();

export function readPref(): ThemePref {
  try {
    const v = localStorage.getItem(THEME_KEY);
    return v === "light" || v === "dark" ? v : "system";
  } catch { return "system"; }
}

export const prefersDark = () => typeof matchMedia === "function" && matchMedia("(prefers-color-scheme: dark)").matches;
export const resolve = (pref: ThemePref): "light" | "dark" => (pref === "dark" || (pref === "system" && prefersDark()) ? "dark" : "light");

/** Sets data-theme on <html>. The inline script in index.html does the same before first paint (DSN-02). */
export function applyTheme(pref: ThemePref) { document.documentElement.dataset.theme = resolve(pref); }
export const initTheme = () => applyTheme(readPref());

export function savePref(pref: ThemePref) {
  try { localStorage.setItem(THEME_KEY, pref); } catch { /* storage may be blocked; the choice still applies for this visit */ }
  applyTheme(pref);
  listeners.forEach((l) => l());
}

const subscribe = (cb: () => void) => { listeners.add(cb); return () => { listeners.delete(cb); }; };

/** The stored preference, shared by every component that shows the toggle. */
export function useTheme() {
  const pref = useSyncExternalStore(subscribe, readPref, () => "system" as ThemePref);
  useEffect(() => {
    applyTheme(pref);
    if (typeof matchMedia !== "function") return;
    const mq = matchMedia("(prefers-color-scheme: dark)");
    const on = () => pref === "system" && applyTheme("system");
    mq.addEventListener("change", on);
    return () => mq.removeEventListener("change", on);
  }, [pref]);
  const setPref = useCallback((p: ThemePref) => savePref(p), []);
  return { pref, setPref };
}

/** The resolved theme ("light" | "dark"), for canvas code that has to re-read CSS variables when it changes. */
export function useResolvedTheme(): "light" | "dark" {
  return useSyncExternalStore(
    (cb) => {
      const mo = new MutationObserver(cb);
      mo.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
      return () => mo.disconnect();
    },
    () => (document.documentElement.dataset.theme === "dark" ? "dark" : "light"),
    () => "light",
  );
}
