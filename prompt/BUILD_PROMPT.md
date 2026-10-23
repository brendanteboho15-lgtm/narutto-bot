# BUILD PROMPT — "Narutto AfriQa Bot" (AI chart-scanner + MT5 trade bridge, Android)

Paste this whole prompt into any capable coding AI. It is written from a frame-by-frame study of the reference video (a phone app called "Zetavia AI"). Everything below is original: own name, own logo, own colours.

---

## 1. What the reference app does (from the video)

1. **Home screen** – dark cyber theme, red glow. Round robot avatar, bot name, one-line tagline, three big buttons: **PAIRS** (left), **START** (large red centre button), **LOGS** (right). Under it a "Powered by" chip, a **Robot List** with the bot and a red remove button, and an **Add New Trading Bot** row.
2. **Bottom tab bar** – Home · Metatrader · Scanner · Settings.
3. **Scanner screen** (the core feature)
   - Dashed upload card: avatar, "Ready to Scan", "Upload a chart screenshot or take a photo", buttons **Choose Image** (red) and **Take Photo** (grey).
   - After an image is picked: thumbnail preview, an optional **+ Add More Timeframes** row (multi-timeframe analysis), and a big red **Analyze Chart** button.
   - While analysing: red corner brackets around the screenshot, a red scan line sweeping down it, pulsing avatar, "Analyzing chart… AI is scanning patterns and levels", animated dots.
   - **Signal card**: bot name + green dot, "Signal generated just now", **BUY/SELL** pill, symbol (XAUUSD) + timeframe chip (M30), a risk badge (MEDIUM), three tiles **ENTRY / TAKE PROFIT / STOP LOSS** (entry white, TP green, SL red), a **Confidence** bar, and a green **Take Trade** button.
   - **Take Trade** → button shows "Placing Trade…" → then "✓ Trade Placed" with "Trade placed (0.01 lots)". In MT5 the chart then shows the BUY 0.01 line with TP and SL lines at exactly the signal levels, and the position appears in Positions/History with the bot's comment.
   - **Scan History** (collapsible, with a count): each item = symbol, BUY/SELL tag, bot name, Entry/TP/SL, screenshot thumbnail, age ("9h ago"), **Delete**, plus **Clear All History**.
4. **Metatrader tab** – connection to the user's MT5 account through a bridge ("EAConnect"): an Expert Advisor on the MT5 terminal receives signals from the app and executes them.
5. **Settings** – account/config.

## 2. What to build

Build **Narutto AfriQa Bot**: same flow and feel, my branding, running on an **Android phone** (installable PWA – no computer needed to use it), plus the two pieces that make "Take Trade" real.

### Components
| Part | Tech | Job |
|---|---|---|
| **App** | Single-page PWA (HTML/CSS/vanilla JS, service worker, manifest, maskable icons), installable via Chrome → Add to Home screen | UI, image handling, calls the Claude vision API, signal card, history, Take Trade |
| **Bridge** | Node.js, zero dependencies, JSON file storage | Queue between app and MT5; token-protected; CORS |
| **EA** | MQL5, `NaruttoBridge.mq5` | Polls bridge with `WebRequest`, validates, places the trade with `CTrade`, reports back |

### App requirements
- Name **Narutto AfriQa Bot**, tagline "intelligent, disciplined, precise SMC trading AI". Original emblem (fox/hex shape), dark `#07080c` background, red `#ff2d3a` accent, green `#22c55e`, font system-ui. Mobile-first, 360–430 px wide, safe-area aware, bottom tab bar (Home, Metatrader, Scanner, Settings).
- **Home**: avatar, START / PAIRS / LOGS. START toggles the bridge heartbeat (green "Bridge online" / red "offline"). PAIRS = pick enabled symbols (default XAUUSD, BTCUSD). LOGS = timestamped activity log. Robot list + add-bot row.
- **Scanner**: Choose Image (multiple allowed), Take Photo (`capture="environment"`), thumbnails with remove, **Add More Timeframes** (extra screenshots, first one is the trigger timeframe, the rest are higher-timeframe context), Analyze Chart, scan animation, signal card, Take Trade, history.
- Downscale each image client-side (max 1568 px long edge, JPEG 0.85) before sending.
- **AI call**: browser → `https://api.anthropic.com/v1/messages` with headers `x-api-key`, `anthropic-version: 2023-06-01`, `anthropic-dangerous-direct-browser-access: true`. API key and model are entered in Settings and stored only in `localStorage` on the phone. Never hard-code a key.
- **Output is strict JSON** (also viewable/copyable in the UI):
```json
{
  "signal": "BUY | SELL | WAIT",
  "symbol": "XAUUSD", "timeframe": "M30",
  "entry": 0.0, "sl": 0.0, "tp": 0.0, "rr": 0.0,
  "confidence": 0, "risk": "LOW | MEDIUM | HIGH",
  "bias": "bullish | bearish | range",
  "structure": "BOS/CHoCH reading", "poi": "order block / FVG / zone used",
  "liquidity": "sweeps / equal highs-lows", "reasons": ["..."],
  "invalidation": "what cancels the idea", "warnings": ["..."]
}
```
- **Analysis system prompt** (Smart Money Concepts): top-down read — higher timeframe bias, market structure (BOS, CHoCH), liquidity (equal highs/lows, sweeps), points of interest (order blocks, FVG, supply/demand, flip levels), wait for CHoCH/BOS confirmation, entry from the POI, SL beyond the invalidation swing, TP at the next liquidity pool. Rules: read symbol, timeframe and prices **only from what is visible** on the chart (price axis, header); never invent levels; if the chart is unreadable or there is no clean setup, return `"signal":"WAIT"`; minimum RR 1.5; reply with JSON only.
- **App-side validation after the AI answers** (don't trust the model blindly): numbers parse; BUY needs `sl < entry < tp`, SELL needs `tp < entry < sl`; RR ≥ 1.5; otherwise downgrade to WAIT and show why. WAIT shows a neutral card with no Take Trade button.
- **Take Trade**: confirm sheet with lot size (default from Settings) → `POST {bridge}/signal` → poll status → "Placing Trade…" → "Trade Placed (0.01 lots)" or the broker's error. If no bridge is configured, copy a plain-text order ticket to the clipboard instead.
- History in `localStorage` (cap 50), delete one / clear all, thumbnails as small data-URLs.
- Offline-capable shell via service worker. No third-party scripts.

### Bridge requirements
- `POST /signal` (app → queue), `GET /pending` (EA pulls one line: `id|SYMBOL|SIDE|entry|sl|tp|lots`), `POST /report` (EA → result), `GET /signal/:id`, `GET /trades`, `GET /health`.
- `X-Token` header required on everything except `/health`. Pending signals expire after 120 s. Reject bad numbers, lots > cap, unknown sides. Atomic JSON file persistence. CORS for the app.

### EA requirements (L99 standard)
- MQL5, `#property strict`, ASCII-only source, balanced braces, `CTrade`, inputs: bridge URL, token, poll seconds, magic number, symbol suffix (Exness: e.g. `m` or empty), max spread (points), max entry drift (points), max lots, allow-trading switch.
- Pre-trade checks: symbol exists & is selectable, spread ≤ limit, price within drift of the signal entry, SL/TP on the correct side, stop-level distance respected, lots normalised to min/max/step, duplicate signal ids ignored.
- Market order with the signal's SL and TP, comment `NaruttoBot <id>`, report ticket/price/error back to the bridge. Chart comment showing connection status. No chart objects accumulate.

## 3. Safety rules (non-negotiable)
- Default to **demo account** and **0.01 lots**. Show a visible "Not financial advice – AI can be wrong" line on the scanner.
- The EA must refuse to trade when `InpAllowTrading=false`.
- No martingale, no lot auto-scaling from the AI output.

## 4. Deliverables
1. `app/` — `index.html`, `manifest.webmanifest`, `sw.js`, icons.
2. `bridge/server.js`.
3. `ea/NaruttoBridge.mq5`.
4. A short phone-only setup guide (host the app, get an API key, run the bridge, attach the EA, allow WebRequest URL in MT5).
5. Test evidence: UI screenshots at phone size, bridge curl test, EA brace/ASCII audit.
