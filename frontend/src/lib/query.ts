import { QueryClient, useQuery } from "@tanstack/react-query";
import { api, ApiError } from "./api";

export const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: (n, e) => !(e instanceof ApiError && e.status < 500 && e.status !== 0) && n < 2, staleTime: 5_000 } },
});

// Polling pauses automatically while the tab is hidden (refetchIntervalInBackground defaults to false).
export const POLL = 15_000;

export const useMe = () => useQuery({ queryKey: ["me"], queryFn: api.me, retry: false, staleTime: 60_000 });
export const usePortfolio = () => useQuery({ queryKey: ["portfolio"], queryFn: api.portfolio, refetchInterval: POLL });
export const useMarket = () => useQuery({ queryKey: ["market"], queryFn: api.marketStatus, refetchInterval: 60_000 });
export const useMarketOverview = () => useQuery({ queryKey: ["market-overview"], queryFn: api.marketOverview, refetchInterval: 60_000, retry: false });
