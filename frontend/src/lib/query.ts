import { QueryClient, useQuery } from "@tanstack/react-query";
import { api, ApiError } from "./api";

export const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: (n, e) => !(e instanceof ApiError && e.status < 500 && e.status !== 0) && n < 2, staleTime: 5_000 } },
});

// Polling pauses automatically while the tab is hidden (refetchIntervalInBackground defaults to false).
// SCL-12: 15 s while the user is active on this tab, 60 s after 2 minutes without input. 200 open tabs then cost the
// server about 200 / 60 requests a second per endpoint instead of 200 / 15.
export const POLL = 15_000;
export const POLL_IDLE = 60_000;
export const IDLE_AFTER = 120_000;

let lastActivity = Date.now();
export const noteActivity = (at = Date.now()) => { lastActivity = at; };
export const pollInterval = (now = Date.now()) => (now - lastActivity > IDLE_AFTER ? POLL_IDLE : POLL);
if (typeof window !== "undefined") {
  for (const ev of ["pointerdown", "keydown", "scroll", "visibilitychange"]) window.addEventListener(ev, () => noteActivity(), { passive: true });
}

export const useMe = () => useQuery({ queryKey: ["me"], queryFn: api.me, retry: false, staleTime: 60_000, refetchInterval: 60_000 });
export const usePortfolio = () => useQuery({ queryKey: ["portfolio"], queryFn: api.portfolio, refetchInterval: () => pollInterval() });
export const useMarket = () => useQuery({ queryKey: ["market"], queryFn: api.marketStatus, refetchInterval: 60_000 });
export const useMarketOverview = () => useQuery({ queryKey: ["market-overview"], queryFn: api.marketOverview, refetchInterval: 60_000, retry: false });
