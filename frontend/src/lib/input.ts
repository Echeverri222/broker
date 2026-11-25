// Client-side checks mirror the API rules (ORD-02, DEP-01) so the UI blocks what the server would reject.
// They never produce numbers that are sent back as truth: we only send the string the user typed.
const PLAIN = /^\d+(\.\d+)?$/;

/** People type "$1,000" or " 50 ": drop the dollar sign, thousands commas and spaces before validating. */
export const cleanNumber = (v: unknown) => String(v ?? "").replace(/[$,\s]/g, "");

export type Mode = "amount" | "quantity";
export const MAX_PLACES: Record<Mode, number> = { amount: 2, quantity: 8 };

/** Returns an error message, or null when the typed value is acceptable. */
export function validateTradeInput(raw: string, mode: Mode): string | null {
  const v = raw.trim();
  if (!v) return "Enter a number";
  if (!PLAIN.test(v)) return "Use digits and an optional decimal point only";
  if (!(Number(v) > 0)) return "Must be greater than zero";
  const places = v.split(".")[1]?.length ?? 0;
  if (places > MAX_PLACES[mode]) return mode === "amount" ? "Use dollars and cents, e.g. 250.00" : "At most 8 decimal places";
  return null;
}

/** UX-02: one idempotency key per distinct request; a new key only when the inputs change. */
export function makeKeyStore(gen: () => string) {
  let sig = "";
  let key = gen();
  return {
    keyFor(inputs: unknown): string {
      const s = JSON.stringify(inputs);
      if (s !== sig) { sig = s; key = gen(); }
      return key;
    },
  };
}
