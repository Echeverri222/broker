# PRD v3: UI redesign, rich charts and filters

Status: approved direction. Builds on `PRD.md` (v2, including queued orders QUE-01..09). Nothing in v2 may regress.

Design reference (the source of truth for look and layout):
- Canvas: https://claude.ai/artifact/4bfu9Tn3gSeZsyjsTwZPps (private; may not be openable by you)
- Local copies, read these first: `/private/tmp/claude-501/-Users-macbookairm222c100-broker/a8df3e66-c92d-4c46-b35b-234519dba132/scratchpad/design/project/`
  - `HomeV2.dc.html` (light) and `HomeV2Dark.dc.html` (dark): Home
  - `AssetV2.dc.html`: asset page with candles, overlays, key numbers, trade panel
  - `MarketsV2.dc.html`: Markets with filters and sort
  - `Welcome.dc.html`, `MobileHome.dc.html`, `MobileTrade.dc.html`, `MobileReceipt.dc.html`: welcome and 390px mobile
  - `Main.dc.html`, `Asset.dc.html`: older versions, ignore where V2 exists
- The mockups are HTML/SVG with sample numbers. Reproduce layout, spacing, type, colour tokens and states. Do not copy the sample numbers.

## 1. Goals
1. A product people enjoy opening: calm, confident, fintech-grade (reference: Mercury, Ramp), not loud.
2. Real data to explore: candlestick charts, overlays, compare, key numbers, filters and sorting.
3. Every screen stays clear for a non-technical user. Plain words, one primary action per view.

## 2. Non-goals
- No new trading rules, no limit orders, no real money. Queued orders (QUE-*) stay exactly as they are.
- No third-party logo hotlinking. No emoji. No marketing site.
- No new paid data providers. Only Yahoo (stocks, ETFs) and CoinGecko (crypto) as today.

## 3. Design system (rules DSN-*)
- **DSN-01 Tokens.** All colours, radii and spacing come from CSS variables defined once in `frontend/src/styles` (Tailwind theme extended from them). Light tokens: `--bg #F3F2EF`, `--card #FFFFFF`, `--well #ECEBE7`, `--line #E4E2DC`, `--ink #111114`, `--mute #6B6B73`, `--accent #2F66D9`, `--gain #12803F`, `--loss #C62F2F`, `--amber #A85F12`, `--amber-bg #FFF3E3`. Dark tokens as in `HomeV2Dark.dc.html`. No hard-coded hex in components.
- **DSN-02 Theme.** Light, dark and "match my device" (default). Toggle in Settings and in the account menu. Choice persists in localStorage (guarded by try/catch) and applies before first paint (no flash).
- **DSN-03 Type.** Inter (400/500/600/700) with tabular numbers everywhere money or percentages appear. Page titles 44-52px weight 600, tracking -0.04em. Two-tone titles: first clause `--ink`, second clause `--mute`.
- **DSN-04 Money.** Amounts render with raised small cents ("$104,862" + superscript "40") in headline and list contexts, through one `<Money>` component. Plain `$1,234.56` text remains in tables, receipts, inputs and aria-labels. Screen readers always get the full amount.
- **DSN-05 Colour use.** Gain/loss colour only on changes, and always paired with ▲/▼. Amber only for "waiting" (queued) states. One accent colour (blue) for the primary action. Contrast: text 4.5:1 minimum in both themes (vitest-axe plus a contrast test on the token pairs).
- **DSN-06 Cards.** 24px radius, 1px `--line` border, no heavy shadows. Card titles are `18/600` with a muted second part (`Your portfolio · practice money`). A 36px corner button (square, `↗` icon) links to the detail view of a card.
- **DSN-07 Icons.** One stroke icon set (lucide-react, 1.5-2px stroke). Company logos: if the asset has `logo_url` use it, else an initials tile in a circle. Never hotlink external logo services.
- **DSN-08 Motion.** Subtle only: 150ms hover lift on rows, number tween on the portfolio value, chart draw-in under 400ms. Respect `prefers-reduced-motion` (no motion). No confetti, no streaks, no gamified rewards.
- **DSN-09 Layout.** Max content width 1200px, 32px gutters (16px on phones). Home, Asset, Markets match the mockups at 1360px. At 390px: single column, bottom tab bar (Home, Markets, Activity, Watchlist, 56px min height), trade opens as a bottom sheet. No horizontal page scroll at 320px.
- **DSN-10 Touch and focus.** Every control at least 44x44px hit area. Visible 3px focus ring using `--accent` at 45% alpha. Real buttons and links only.

## 4. Home (rules HOME-*)
- **HOME-01** Greeting headline with two tones: "Good morning, {name}." then a muted status clause: market open ("Markets close at 4:00 PM.") or closed ("Markets open Monday at 9:30."). Name falls back to the email prefix. Greeting by local hour.
- **HOME-02** Action pills under it: Buy (filled accent), Sell, Add cash, Watch. Buy/Sell open the symbol picker (search) then the existing trade sheet. Add cash opens the existing deposit sheet. Watch goes to Markets filtered to nothing with search focused.
- **HOME-03** Markets strip: S&P 500 (via SPY), Nasdaq (via QQQ), Bitcoin: label, value chip, day change. Label the proxies in a tooltip ("Tracked with the SPY fund"). Hidden gracefully if quotes are missing.
- **HOME-04** Portfolio card: raised-cents value, today change, all-time change, range tabs 1D 1W 1M 3M 1Y, line chart of portfolio value with dashed S&P 500 comparison, legend, and the "N% ahead of / behind the market" line when benchmark data exists. Today uses the existing corrected day-change logic.
- **HOME-05** Accounts card: Cash to spend, Set aside for orders (reserved), Invested, with a 3-segment bar. Corner button opens Activity.
- **HOME-06** Waiting-orders card (amber) shown only when pending orders exist: count, first order summary, Cancel. Hidden otherwise.
- **HOME-07** Holdings card: logo, name, quantity, 30-day sparkline, value (raised cents), day change. Rows link to the asset page. Empty state: one sentence plus a Buy button, no empty table.
- **HOME-08** First-run checklist ("Get started", 4 steps: account, first buy, watch something, sell and see profit) shown on Home until all done or dismissed; progress derived from real data (orders, watchlist), dismissal stored per user in localStorage.

## 5. Asset page and charts (rules CHT-*)
- **CHT-01 Chart types.** Line, Area, Candles. Selection persists per user (localStorage). Default: Line for 1D/1W, Candles never forced.
- **CHT-02 Ranges.** 1D, 1W, 1M, 3M, 6M, 1Y, 5Y, All. `6M` and `ALL` are new API ranges. Each range has a default candle size; viewer can override with a candle-size selector (1h / 1D / 1W) limited to sensible combinations (the API rejects others with 422 `validation_failed`).
- **CHT-03 Candles.** Green up / red down candles with wicks, from OHLC. Up/down is also shown by hollow vs filled body so it does not rely on colour alone (a setting-free default).
- **CHT-04 Volume.** Volume histogram under the price pane, tinted by direction, toggleable. Crypto may lack volume: hide the toggle when `volume` is null for the whole series.
- **CHT-05 Overlays.** Toggle chips: Average 10, Average 20 (simple moving averages of close, computed client-side from the loaded candles, hidden when fewer candles than the period), Volume, Your trades, Compare. Chip dot shows the line colour.
- **CHT-06 Your trades.** Markers on the chart at the candle of each of the user's filled orders for this asset (Buy / Sell label, tooltip with quantity and price) and a dashed horizontal line at the average cost with a "You paid {price}" tag. Pending orders are not marked as fills.
- **CHT-07 Compare.** "Compare with S&P 500" and "Compare with…" (symbol picker). Compared series is rebased to the first visible close = 100 and the primary series is too; the axis switches to "% change" while compare is on. Max one comparison.
- **CHT-08 Crosshair.** Hover or touch-drag shows a dotted vertical/horizontal crosshair and a tooltip card: date, Open, High, Low, Close (candles) or Price (line), Volume, and change vs the previous candle. Keyboard: with the chart focused, Left/Right move the crosshair candle by candle, Home/End jump to first/last. The same values are exposed in a visually hidden live region.
- **CHT-09 Last price tag.** Coloured tag on the right axis for the latest price; price axis on the right with 4-6 ticks; time axis labels adapted to the range.
- **CHT-10 Range summary.** Above the chart: price, today change, and for the selected range "from open to now" change in $ and %.
- **CHT-11 Key numbers card.** Open, Yesterday's close, Volume, Average volume, 1 month and 1 year change, Today's range bar (low-high with marker), 52-week range bar. Missing values show "–" and the row stays. Data in section 7.
- **CHT-12 Portfolio chart parity.** Home portfolio chart uses the same chart component (line/area, crosshair, compare to S&P 500). Candles do not apply to the portfolio.
- **CHT-13 Performance.** Chart renders 1,000 candles without jank; indicator and overlay toggles do not refetch. The candles request is cached per (symbol, range, interval) for 60s in TanStack Query.
- **CHT-14 States.** Loading skeleton with the chart's aspect ratio, error card with Retry, empty state "No price history for this range". Price unavailable disables trading exactly as UX-05.
- **CHT-15 Trade panel.** Right column on desktop (sticky), bottom sheet on mobile. Contents and queued-order copy exactly as in `AssetV2.dc.html` and QUE-*. Buy/Sell segmented control, amount-first input with chips ($100, $500, $1,000, All cash), summary rows, one primary button ("Buy", "Sell", "Queue buy for Monday").

## 6. Markets (rules FLT-*)
- **FLT-01** Search box (existing fuzzy search, results update after 200ms debounce, query kept in the URL as `?q=`).
- **FLT-02** "Show" chips with counts: All, Stocks, Crypto, ETFs, Watching, You own. Single select. Counts come from the API and respect the current search.
- **FLT-03** Quick picks (multi-select, combinable with FLT-02): Top gainers, Top losers, Most traded, Near 52-week high, Under $50, Open now (assets tradable right now: crypto always, stocks only while open). "Clear filters" resets everything.
- **FLT-04** Sort dropdown: Biggest move today (default), Price (low-high, high-low), Name A-Z, Most traded, Biggest 1-month move.
- **FLT-05** Sector filter (dropdown) for stocks/ETFs. Crypto has sector "Crypto".
- **FLT-06** Table columns: Name (logo, name, ticker, kind and sector), Price, Today, 52-week range bar, Last month sparkline, Watch star (toggle in place, optimistic). Whole row links to the asset page. Sticky header on desktop. On phones rows become two-line cards (name + price / change + sparkline).
- **FLT-07** Pagination by "Show more" (page size 25). Total shown as "Showing N of M".
- **FLT-08** All filter/sort state lives in the URL query string so the view is shareable and back/forward works.
- **FLT-09** Empty result: "Nothing matches. Try fewer filters." with a Clear filters button. When the search is a near-miss the API's fuzzy result is shown with "Showing results for X".
- **FLT-10** Keyboard: `/` focuses search, `Esc` clears it. Chips are a radio group / toggle buttons with correct ARIA.

## 7. Data and API changes (rules DAT-*)
All changes are additive and documented in `backend/openapi.yml` (regenerate the frontend types and keep `check:api` green).
- **DAT-01 Volume.** `GET /assets/{symbol}/candles` adds `volume` (string integer or null) per candle. Yahoo supplies it; CoinGecko returns null.
- **DAT-02 Ranges and interval.** Ranges become `1D 1W 1M 3M 6M 1Y 5Y ALL`. New optional `interval` param: `1h`, `1d`, `1w`. Valid combos: 1D→1h; 1W→1h,1d; 1M→1d; 3M→1d,1w; 6M→1d,1w; 1Y→1d,1w; 5Y→1d,1w; ALL→1w. Defaults: 1D 1h(5m for 1D is fine if the provider has it), 1W 1h, 1M-1Y 1d, 5Y 1w, ALL 1w. Invalid combo: 422 `validation_failed`. Candle cache keys include the interval.
- **DAT-03 Key numbers.** `GET /assets/{symbol}` adds `stats`: `open`, `day_low`, `day_high`, `week52_low`, `week52_high`, `volume`, `avg_volume`, `change_1m_percent`, `change_1y_percent` (any may be null). Sourced from Yahoo chart meta/quote data already fetched for quotes where possible; cached with the quote (no extra provider call per page view beyond today's `refresh_one`). Crypto stats come from CoinGecko market data (24h high/low, volume; no 52-week values: use the 1Y candle high/low).
- **DAT-04 Sector.** New `assets.sector` string column (migration, nullable). Seed a sector for every asset in the universe (e.g. Technology, Financials, Health care, Energy, Consumer, Industrials, Communication, Crypto, Index funds). Exposed in `Presenters.asset`.
- **DAT-05 List endpoint.** `GET /assets` accepts `kind` (stock|etf|crypto), `filter` (comma list of `watching,owned,gainers,losers,most_traded,near_high,under_50,open`), `sector`, `sort` (`change|price_asc|price_desc|name|volume|change_1m`), `page`, `limit` (max 50, default 25), `q`. Response adds `meta: { total, page, limit, counts: { all, stock, etf, crypto, watching, owned }, sectors: [...] }` where counts respect `q` but not `kind`. Each asset includes `change_percent`, `week52_position` (0-1 or null), `spark` (array of up to 30 daily closes as strings, or null) and `volume`. Invalid values: 422 `validation_failed`.
- **DAT-06 Warm data.** A recurring job (hourly, `config/recurring.yml`) fills Solid Cache with each active asset's 1M daily closes (for `spark`), 52-week high/low and volume, using at most one provider call per asset per run, throttled and failure-tolerant (a failing asset keeps its previous cached value; the job never raises). The list endpoint reads only the cache, never calls providers.
- **DAT-07 User trades for charts.** `GET /orders?symbol=&status=filled&limit=200` already exists; confirm it returns what CHT-06 needs (`side`, `quantity`, `price`, `filled_at`). Add only if something is missing.
- **DAT-08 Market strip.** `GET /market/overview` (auth not required, like `/market/status`) returns `{ items: [{ symbol, label, price, change_percent, proxy_for }] }` for SPY, QQQ, BTC from cached quotes, 60s cache. Missing quotes are omitted.

## 8. Welcome, auth and settings (rules WEL-*)
- **WEL-01** Welcome matches `Welcome.dc.html`: large two-line headline, short subline, form (Name optional, Email, Password with "At least 8 characters"), primary button "Create account", sign-in link, right-hand sample portfolio card (static, clearly illustrative, no real user data).
- **WEL-02** Settings gets Appearance (Light / Dark / Match device), plus existing reset, sign out, and password-strength hint. Page is centred, same width as other pages.

## 9. Acceptance and quality bar
- **QA-01** Backend: every DAT-* rule has request/service specs citing its ID in the example name (`[DAT-05]` etc.). `bundle exec rspec` green, rubocop clean, `openapi.yml` updated and committee response validation passing.
- **QA-02** Frontend: Vitest + Testing Library tests citing IDs for: `<Money>` (DSN-04), theme persistence and no-flash class (DSN-02), chart toolbar state, SMA calculation, rebasing for compare (CHT-07), keyboard crosshair (CHT-08), filter-to-URL round trip (FLT-08), empty states, first-run checklist (HOME-08). vitest-axe passes on Home, Asset, Markets, Welcome in both themes.
- **QA-03** `script/rule_coverage` updated to include the prefixes `DSN HOME CHT FLT DAT WEL QA` and exits 0 with every rule ID cited by at least one test.
- **QA-04** `npx tsc --noEmit`, `npx vitest run`, `npm run build` pass. `npm run check:api` is wired into CI (`.github/workflows` or the existing CI file).
- **QA-05** No visual regressions in behaviour covered by v2: queued orders (QUE-*), deposits, reset, Activity cancel. Existing tests stay green; update them only where copy or markup intentionally changed.
- **QA-06** Verify in a real browser (Chrome tool) at 1360px and 390px, light and dark: Welcome, Home, Markets with each filter type, Asset with Line/Area/Candles, each overlay, Compare, crosshair, queued order flow. Fix what is visibly broken. Report what was checked and what was not.
- **QA-07** README updated (new endpoints, theme, how to run, deviations).

## 10. Suggested build order
1. Tokens, theme, `<Money>`, layout shell, nav (DSN, WEL).
2. Backend DAT-01..06, 08 with specs and OpenAPI, then regenerate frontend types.
3. Chart component (CHT-01..10, 12..14) on top of lightweight-charts, then Asset page and trade panel (CHT-11, 15).
4. Markets (FLT-*).
5. Home (HOME-*).
6. Mobile pass, a11y pass, coverage script, README, browser verification.
