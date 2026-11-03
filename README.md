# Narutto AfriQa Bot - phone-only setup

1. **Host the app** (needs HTTPS to install): upload the `app/` folder to Netlify Drop, Cloudflare Pages or GitHub Pages. Open the link in Chrome on Android -> menu -> "Add to Home screen".
2. **API key**: create an Anthropic API key (set a spend limit). Settings tab -> paste key -> Save.
3. **Bridge** (needed only for Take Trade): run `bridge/server.js` on any always-on host (Windows VPS, Render, Railway, Fly). `BRIDGE_TOKEN=yourSecret node server.js`. Put it behind HTTPS.
4. **EA**: copy `ea/NaruttoBridge.mq5` into MT5 `MQL5/Experts`, compile. MT5 -> Tools -> Options -> Expert Advisors -> tick "Allow WebRequest" and add your bridge URL. Attach EA to any chart, set URL + same token. Exness cent/pro accounts: set InpSymbolSuffix (e.g. `m`) if symbols have one. AutoTrading must be ON.
5. App -> Metatrader tab -> enter bridge URL + token -> Test connection. Scanner -> upload chart -> Analyze -> Take Trade.

Start on a DEMO account at 0.01 lots. Without a bridge, Take Trade copies the order ticket for manual entry.

## Running trades screen
With the EA attached, the Metatrader tab shows balance, equity, running trades with live profit/loss and a bar between SL and TP, and closed trades marked WIN or LOSS (TP / SL / MANUAL). The EA sends this to the bridge every few seconds.

## Journal & Stats tab
Mark each signal Win (TP), Loss (SL) or Break-even. The app computes win rate, total R, average R per trade, profit factor, max drawdown, an equity curve and per-pair results, and warns when there are too few results to trust. Export CSV or Copy CSV.

## Auto-Trade (full auto-take)
The EA uploads closed candles (M5, M15, H1, H4) at every new M5 bar. The bridge asks Claude, checks the answer, applies the safety limits and queues a market order. The EA sizes the lots from RISK_PCT and the stop distance.

Render environment variables (Environment tab):
- ANTHROPIC_API_KEY  (required, use a NEW key with a spend limit)
- BRIDGE_TOKEN       (already set)
- AUTO_MODE          scalp (default) or swing
- RISK_PCT           0.5   (% of balance risked per trade)
- MAX_OPEN           1
- MAX_TRADES_DAY     3
- DAILY_LOSS_PCT     2     (auto stops for the day)
- MIN_CONF           65
- MAX_SCANS_DAY      40    (API budget guard)
- SCAN_EVERY_MIN     15    (minutes between AI scans per symbol)
- AUTO_SYMBOLS       XAUUSD,BTCUSD

Auto is always OFF after a restart. Switch it on in the app: Metatrader tab -> Auto-Trade -> Turn ON. STOP switches it off and cancels any waiting order.
Attach the EA to one chart per symbol (XAUUSD and BTCUSD). Demo account first.
