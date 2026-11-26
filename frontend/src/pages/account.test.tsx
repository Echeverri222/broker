import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { axe } from "vitest-axe";
import { ApiError } from "../lib/api";
import { IDLE_AFTER, POLL, POLL_IDLE, noteActivity, pollInterval } from "../lib/query";

const calls: Record<string, unknown[][]> = {};
const rec = (k: string, ...a: unknown[]) => { (calls[k] ??= []).push(a); };
let me: Record<string, unknown>;
let sessions: Array<Record<string, unknown>>;
let failWith: ApiError | null = null;

vi.mock("../lib/api", async (orig) => {
  const real = await orig<typeof import("../lib/api")>();
  const maybeFail = async () => { if (failWith) throw failWith; };
  return { ...real, api: { ...real.api,
    me: async () => me,
    sessions: async () => ({ sessions }),
    revokeSession: async (id: number) => { rec("revokeSession", id); },
    revokeOtherSessions: async () => { rec("revokeOthers"); },
    changePassword: async (b: unknown) => { await maybeFail(); rec("changePassword", b); },
    preferences: async (b: Record<string, boolean>) => { rec("preferences", b); me = { ...me, preferences: { ...(me.preferences as object), ...b } }; return me; },
    exportData: async () => { rec("export"); return { orders: [] }; },
    deleteAccount: async (b: unknown) => { await maybeFail(); rec("deleteAccount", b); },
    requestPasswordReset: async (e: string) => { rec("forgot", e); },
    resetPassword: async (b: unknown) => { await maybeFail(); rec("reset", b); },
    verifyEmail: async (t: string) => { await maybeFail(); rec("verify", t); },
    resendVerification: async () => { rec("resend"); },
  } };
});

import Settings, { deviceLabel } from "./Settings";
import { ForgotPassword, ResetPassword, VerifyEmail } from "./Recovery";
import { Banners } from "../components/Banners";

function renderAt(path: string, el: React.ReactElement, route = path.split("?")[0]) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(<QueryClientProvider client={qc}><MemoryRouter initialEntries={[path]}><Routes><Route path={route} element={el} /></Routes></MemoryRouter></QueryClientProvider>);
}

const sess = (id: number, over: Record<string, unknown> = {}) => ({ id, user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/120 Safari/537", ip_address: "1.2.3.4", created_at: "2026-03-01T10:00:00Z", last_seen_at: "2026-03-02T10:00:00Z", current: false, ...over });

beforeEach(() => {
  for (const k of Object.keys(calls)) delete calls[k];
  failWith = null;
  me = { id: 1, name: "Ada", email: "ada@example.test", verified: true, admin: false, trading_enabled: true,
    preferences: { notify_order_filled: false, notify_order_rejected: true }, account: { cash: "1.00", reserved_cash: "0.00", net_deposits: "1.00" } };
  sessions = [sess(1, { current: true }), sess(2, { user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17) Safari/604" })];
});

describe("Settings: sessions and account [SES-04, SES-06, SES-08, SES-10, NTF-02]", () => {
  it("labels devices and marks this one", async () => {
    renderAt("/settings", <Settings />);
    expect(await screen.findByText("Chrome on macOS")).toBeInTheDocument();
    expect(screen.getByText("This device")).toBeInTheDocument();
    expect(screen.getByText("Safari on iOS")).toBeInTheDocument();
    expect(deviceLabel(null)).toBe("Unknown device");
    expect(deviceLabel("Mozilla/5.0 (X11; Linux) Firefox/121")).toBe("Firefox on Linux");
  });

  it("signs out one other device, but never offers it for the current one", async () => {
    renderAt("/settings", <Settings />);
    await screen.findByText("Safari on iOS");
    expect(screen.getAllByRole("button", { name: /^Sign out (?!all)/ })).toHaveLength(1);
    await userEvent.click(screen.getByRole("button", { name: "Sign out Safari on iOS" }));
    await waitFor(() => expect(calls.revokeSession).toEqual([[2]]));
  });

  it("signs out all other devices", async () => {
    renderAt("/settings", <Settings />);
    await userEvent.click(await screen.findByRole("button", { name: "Sign out all other devices" }));
    await waitFor(() => expect(calls.revokeOthers).toHaveLength(1));
  });

  it("changes the password only with both fields filled and 8+ characters, and shows server errors", async () => {
    renderAt("/settings", <Settings />);
    const btn = await screen.findByRole("button", { name: "Change password" });
    expect(btn).toBeDisabled();
    await userEvent.type(screen.getByLabelText("Current password"), "old-password");
    await userEvent.type(screen.getByLabelText("New password"), "short");
    expect(btn).toBeDisabled();
    await userEvent.type(screen.getByLabelText("New password"), "er-and-longer");
    failWith = new ApiError("validation_failed", "Current password is incorrect.", 422);
    await userEvent.click(btn);
    expect(await screen.findByRole("alert")).toHaveTextContent("Current password is incorrect.");
    failWith = null;
    await userEvent.click(btn);
    expect(await screen.findByRole("status")).toHaveTextContent("Password changed");
    expect(calls.changePassword?.at(-1)).toEqual([{ current_password: "old-password", password: "shorter-and-longer" }]);
  });

  it("saves email preferences as toggles", async () => {
    renderAt("/settings", <Settings />);
    const filled = await screen.findByRole("switch", { name: "Email me when a waiting order is filled" });
    expect(filled).not.toBeChecked();
    expect(screen.getByRole("switch", { name: "Email me when a waiting order could not be filled" })).toBeChecked();
    await userEvent.click(filled);
    await waitFor(() => expect(calls.preferences).toEqual([[{ notify_order_filled: true }]]));
  });

  it("downloads the export", async () => {
    const create = vi.fn(() => "blob:x"); const revoke = vi.fn();
    Object.assign(URL, { createObjectURL: create, revokeObjectURL: revoke });
    renderAt("/settings", <Settings />);
    await userEvent.click(await screen.findByRole("button", { name: "Download my data" }));
    await waitFor(() => expect(create).toHaveBeenCalled());
    expect(calls.export).toHaveLength(1);
  });

  it("needs the password and the exact word DELETE before deleting the account", async () => {
    renderAt("/settings", <Settings />);
    const del = await screen.findByRole("button", { name: "Delete my account" });
    expect(del).toBeDisabled();
    await userEvent.type(screen.getByLabelText("Type DELETE to confirm"), "delete");
    await userEvent.type(screen.getByLabelText("Your password"), "pw-pw-pw-1");
    expect(del).toBeDisabled();
    await userEvent.clear(screen.getByLabelText("Type DELETE to confirm"));
    await userEvent.type(screen.getByLabelText("Type DELETE to confirm"), "DELETE");
    expect(del).toBeEnabled();
    failWith = new ApiError("validation_failed", "Password is incorrect.", 422);
    await userEvent.click(del);
    expect(await screen.findByText("Password is incorrect.")).toBeInTheDocument();
  });

  it("has no accessibility violations", async () => {
    const { container } = renderAt("/settings", <Settings />);
    await screen.findByText("Chrome on macOS");
    expect(await axe(container)).toHaveNoViolations();
  });
});

describe("Password reset and email confirmation [SES-05, SES-07]", () => {
  it("asks for the email and answers the same way whatever the account state", async () => {
    renderAt("/forgot-password", <ForgotPassword />);
    expect(screen.getByRole("button", { name: "Send reset link" })).toBeDisabled();
    await userEvent.type(screen.getByLabelText("Email"), " ada@example.test ");
    await userEvent.click(screen.getByRole("button", { name: "Send reset link" }));
    expect(await screen.findByRole("status")).toHaveTextContent("If there is an account for that email");
    expect(calls.forgot).toEqual([["ada@example.test"]]);
  });

  it("sets a new password from the emailed token", async () => {
    renderAt("/reset-password?token=abc123", <ResetPassword />);
    const btn = screen.getByRole("button", { name: "Change password" });
    await userEvent.type(screen.getByLabelText("New password"), "brand-new-pass");
    await userEvent.click(btn);
    expect(await screen.findByRole("status")).toHaveTextContent("every device was signed out");
    expect(calls.reset).toEqual([[{ token: "abc123", password: "brand-new-pass" }]]);
    expect(screen.getByRole("link", { name: "Sign in" })).toHaveAttribute("href", "/welcome");
  });

  it("explains an expired link and offers a new one", async () => {
    failWith = new ApiError("invalid_token", "This link is invalid or has expired.", 422);
    renderAt("/reset-password?token=old", <ResetPassword />);
    await userEvent.type(screen.getByLabelText("New password"), "brand-new-pass");
    await userEvent.click(screen.getByRole("button", { name: "Change password" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("expired or was already used");
    expect(screen.getByRole("link", { name: "Ask for a new one" })).toHaveAttribute("href", "/forgot-password");
  });

  it("does not offer the form without a token", () => {
    renderAt("/reset-password", <ResetPassword />);
    expect(screen.getByRole("alert")).toHaveTextContent("missing its token");
    expect(screen.queryByLabelText("New password")).toBeNull();
  });

  it("confirms the email once from the link", async () => {
    renderAt("/verify-email?token=tok", <VerifyEmail />);
    expect(await screen.findByRole("status")).toHaveTextContent("your email is confirmed");
    expect(calls.verify).toEqual([["tok"]]);
  });

  it("reports a bad confirmation link", async () => {
    failWith = new ApiError("invalid_token", "x", 422);
    renderAt("/verify-email?token=bad", <VerifyEmail />);
    expect(await screen.findByRole("alert")).toHaveTextContent("expired or was already used");
  });
});

describe("Banners [SES-07, ADM-05]", () => {
  it("shows nothing for a verified user while trading is on", async () => {
    const { container } = renderAt("/", <Banners />, "/");
    await waitFor(() => expect(container.querySelector("[role=status]")).toBeNull());
  });

  it("asks an unverified user to confirm and lets them resend", async () => {
    me = { ...me, verified: false };
    renderAt("/", <Banners />, "/");
    expect(await screen.findByText(/Confirm your email/)).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Resend" }));
    expect(await screen.findByText("Sent. Check your inbox.")).toBeInTheDocument();
    expect(calls.resend).toHaveLength(1);
  });

  it("tells everyone when trading is paused, in plain words", async () => {
    me = { ...me, trading_enabled: false };
    renderAt("/", <Banners />, "/");
    expect(await screen.findByText(/Trading is paused for maintenance/)).toBeInTheDocument();
  });
});

describe("Adaptive polling [SCL-12]", () => {
  afterEach(() => noteActivity());

  it("polls every 15 s while the user is active and every 60 s after 2 idle minutes", () => {
    const t0 = 1_000_000;
    noteActivity(t0);
    expect(pollInterval(t0 + 1_000)).toBe(POLL);
    expect(pollInterval(t0 + IDLE_AFTER)).toBe(POLL);
    expect(pollInterval(t0 + IDLE_AFTER + 1)).toBe(POLL_IDLE);
    expect(POLL).toBe(15_000);
    expect(POLL_IDLE).toBe(60_000);
    expect(IDLE_AFTER).toBe(120_000);
  });

  it("goes back to 15 s as soon as the user does something", () => {
    noteActivity(0);
    expect(pollInterval(500_000)).toBe(POLL_IDLE);
    window.dispatchEvent(new Event("pointerdown"));
    expect(pollInterval()).toBe(POLL);
  });
});
