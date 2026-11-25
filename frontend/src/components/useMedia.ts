import { useEffect, useState } from "react";

/** matchMedia as state. Falls back to `fallback` where matchMedia does not exist (tests). */
export function useMedia(query: string, fallback = true) {
  const get = () => (typeof matchMedia === "function" ? matchMedia(query).matches : fallback);
  const [v, setV] = useState(get);
  useEffect(() => {
    if (typeof matchMedia !== "function") return;
    const mq = matchMedia(query);
    const on = () => setV(mq.matches);
    mq.addEventListener("change", on);
    on();
    return () => mq.removeEventListener("change", on);
  }, [query]);
  return v;
}
