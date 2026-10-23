# Narutto AfriQa Bot - phone-only setup

1. **Host the app** (needs HTTPS to install): upload the `app/` folder to Netlify Drop, Cloudflare Pages or GitHub Pages. Open the link in Chrome on Android -> menu -> "Add to Home screen".
2. **API key**: create an Anthropic API key (set a spend limit). Settings tab -> paste key -> Save.
3. **Bridge** (needed only for Take Trade): run `bridge/server.js` on any always-on host (Windows VPS, Render, Railway, Fly). `BRIDGE_TOKEN=yourSecret node server.js`. Put it behind HTTPS.
4. **EA**: copy `ea/NaruttoBridge.mq5` into MT5 `MQL5/Experts`, compile. MT5 -> Tools -> Options -> Expert Advisors -> tick "Allow WebRequest" and add your bridge URL. Attach EA to any chart, set URL + same token. Exness cent/pro accounts: set InpSymbolSuffix (e.g. `m`) if symbols have one. AutoTrading must be ON.
5. App -> Metatrader tab -> enter bridge URL + token -> Test connection. Scanner -> upload chart -> Analyze -> Take Trade.

Start on a DEMO account at 0.01 lots. Without a bridge, Take Trade copies the order ticket for manual entry.

## Running trades screen
With the EA attached, the Metatrader tab shows balance, equity, running trades with live profit/loss and a bar between SL and TP, and closed trades marked WIN or LOSS (TP / SL / MANUAL). The EA sends this to the bridge every few seconds.
