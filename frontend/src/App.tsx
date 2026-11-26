import { Link, Navigate, Route, Routes, useLocation } from "react-router-dom";
import { ApiError } from "./lib/api";
import { useMe } from "./lib/query";
import { useTheme } from "./lib/theme";
import { Layout } from "./components/Layout";
import { Skeleton, ErrorBox } from "./components/ui";
import Welcome from "./pages/Welcome";
import Dashboard from "./pages/Dashboard";
import Markets from "./pages/Markets";
import AssetPage from "./pages/AssetPage";
import Activity from "./pages/Activity";
import Settings from "./pages/Settings";
import { ForgotPassword, ResetPassword, VerifyEmail } from "./pages/Recovery";

function Protected() {
  const me = useMe();
  const loc = useLocation();
  if (me.isLoading) return <div className="p-8"><Skeleton className="h-10 w-64" /></div>;
  if (me.error instanceof ApiError && me.error.status === 401) return <Navigate to="/welcome" replace state={{ from: loc.pathname + loc.search }} />;
  if (me.isError) return <div className="p-8"><ErrorBox message="Can't reach the server." onRetry={() => me.refetch()} /></div>;
  return <Layout />;
}

function NotFound() {
  return (
    <div className="mx-auto max-w-md p-8 text-center">
      <h1 className="text-2xl font-bold">Page not found</h1>
      <p className="mt-2 text-mute">That page doesn't exist.</p>
      <Link to="/" className="mt-4 inline-block font-semibold text-accent underline">Go to your dashboard</Link>
    </div>
  );
}

export default function App() {
  useTheme();
  const me = useMe();
  return (
    <Routes>
      <Route path="/welcome" element={me.data ? <Navigate to="/" replace /> : <Welcome />} />
      <Route path="/forgot-password" element={<ForgotPassword />} />
      <Route path="/reset-password" element={<ResetPassword />} />
      <Route path="/verify-email" element={<VerifyEmail />} />
      <Route element={<Protected />}>
        <Route index element={<Dashboard />} />
        <Route path="markets" element={<Markets />} />
        <Route path="assets/:symbol" element={<AssetPage />} />
        <Route path="activity" element={<Activity />} />
        <Route path="settings" element={<Settings />} />
      </Route>
      <Route path="/watchlist" element={<Navigate to="/markets?show=watching" replace />} />
      <Route path="*" element={<NotFound />} />
    </Routes>
  );
}
