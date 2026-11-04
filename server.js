// Narutto AfriQa Bot - signal bridge (zero dependencies)
// Run:  BRIDGE_TOKEN=yoursecret node server.js     (PORT defaults to 8787)
"use strict";
const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = parseInt(process.env.PORT || "8787", 10);
const TOKEN = process.env.BRIDGE_TOKEN || "";
const MAX_LOTS = parseFloat(process.env.MAX_LOTS || "1");
const EXPIRE_MS = 120 * 1000;
const DB_FILE = process.env.DB_FILE || path.join(__dirname, "signals.json");

if (!TOKEN || TOKEN.length < 8) {
  console.error("Set BRIDGE_TOKEN (at least 8 characters) before starting.");
  process.exit(1);
}

let db = { signals: [] };
try { db = JSON.parse(fs.readFileSync(DB_FILE, "utf8")); } catch (e) { /* fresh db */ }
if (!db || !Array.isArray(db.signals)) db = { signals: [] };

let account = { ts: 0, balance: 0, equity: 0, currency: "", open: [], closed: [] };

function save() {
  db.signals = db.signals.slice(-200);
  const tmp = DB_FILE + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(db));
  fs.renameSync(tmp, DB_FILE);
}

function send(res, code, body, type) {
  res.writeHead(code, {
    "Content-Type": type || "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, X-Token",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS"
  });
  res.end(typeof body === "string" ? body : JSON.stringify(body));
}

function readBody(req, max) {
  const limit = max || 20000;
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => { data += c; if (data.length > limit) { reject(new Error("too large")); req.destroy(); } });
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}

function parseBody(raw, ctype) {
  if (!raw) return {};
  if ((ctype || "").indexOf("json") >= 0) { return JSON.parse(raw); }
  const out = {};
  new URLSearchParams(raw).forEach((v, k) => { out[k] = v; });
  return out;
}

function expireOld() {
  const now = Date.now();
  let changed = false;
  for (const s of db.signals) {
    if (s.status === "queued" && now - s.created > EXPIRE_MS) { s.status = "expired"; s.msg = "Not picked up by MT5 in time"; changed = true; }
  }
  if (changed) save();
}

const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : NaN; };

/* =====================================================================
   AUTO-TRADE ENGINE
   The EA uploads closed candles at every new M5 bar. This engine decides
   whether to ask Claude, validates the answer, applies the safety gates,
   then queues a market order sized by RISK_PCT. Auto is OFF at start and
   after every restart; it is switched on from the app (POST /auto).
   ===================================================================== */
const envNum = (name, def, lo, hi) => {
  const n = parseFloat(process.env[name]);
  const v = Number.isFinite(n) ? n : def;
  return Math.min(hi, Math.max(lo, v));
};
const API_KEY = process.env.ANTHROPIC_API_KEY || process.env.ANTHROPIC_KEY || "";
const API_URL = process.env.ANTHROPIC_URL || "https://api.anthropic.com/v1/messages";
const A = {
  model: process.env.AUTO_MODEL || process.env.MODEL || "claude-sonnet-5-5",
  mode: String(process.env.AUTO_MODE || "scalp").toLowerCase() === "swing" ? "swing" : "scalp",
  symbols: String(process.env.AUTO_SYMBOLS || "XAUUSD,BTCUSD").toUpperCase().split(",").map((s) => s.trim()).filter(Boolean),
  risk: envNum("RISK_PCT", 0.5, 0.05, 2),              // % of balance risked per trade
  maxOpen: envNum("MAX_OPEN", 1, 1, 5),                // open positions at the same time
  maxTradesDay: envNum("MAX_TRADES_DAY", 3, 1, 20),
  dailyLoss: envNum("DAILY_LOSS_PCT", 2, 0.5, 10),     // stop for the day when equity falls this % below the day's start
  maxScansDay: envNum("MAX_SCANS_DAY", 40, 1, 300),    // API budget guard
  minConf: envNum("MIN_CONF", 65, 0, 100),
  scanEveryMin: envNum("SCAN_EVERY_MIN", process.env.AUTO_MODE === "swing" ? 60 : 15, 1, 240),
  cooldownMin: envNum("COOLDOWN_MIN", 15, 0, 600)      // after a trade on the same symbol
};
A.minRR = A.mode === "swing" ? 1.5 : 1.2;

if (!db.auto || typeof db.auto !== "object") db.auto = {};
db.auto.enabled = false;                               // always start OFF
db.auto.log = Array.isArray(db.auto.log) ? db.auto.log : [];
db.auto.day = db.auto.day || {};

const lastScan = {};
const lastSkip = {};
const scanning = {};

function today() { return new Date().toISOString().slice(0, 10); }
function dayRec() {
  if (db.auto.day.date !== today()) db.auto.day = { date: today(), startBalance: 0, scans: 0, halted: "" };
  if (!db.auto.day.startBalance && account.equity > 0) db.auto.day.startBalance = account.equity;
  return db.auto.day;
}
function autoTradesToday() {
  const t = today();
  return db.signals.filter((s) => s.source === "auto" && new Date(s.created).toISOString().slice(0, 10) === t &&
    ["queued", "sent", "filled"].indexOf(s.status) >= 0).length;
}
function logAuto(symbol, result, msg, extra) {
  db.auto.log.push(Object.assign({ t: Date.now(), symbol: symbol || "", result, msg: String(msg || "").slice(0, 240) }, extra || {}));
  db.auto.log = db.auto.log.slice(-60);
  save();
}
function skip(symbol, msg) {          // log a skip only when the reason changes
  if (lastSkip[symbol] === msg) return;
  lastSkip[symbol] = msg;
  logAuto(symbol, "SKIP", msg);
}

function gates(symbol, b) {
  if (!db.auto.enabled) return "Auto is OFF";
  if (!API_KEY) return "Server has no ANTHROPIC_API_KEY";
  if (A.symbols.indexOf(symbol) < 0) return symbol + " is not in AUTO_SYMBOLS";
  const acctAge = account.ts ? Date.now() - account.ts : Infinity;
  if (acctAge > 90000) return "No fresh account data from the EA";
  const day = dayRec();
  if (day.halted) return day.halted;
  if (day.startBalance > 0 && account.equity > 0) {
    const lossPct = (day.startBalance - account.equity) / day.startBalance * 100;
    if (lossPct >= A.dailyLoss) {
      day.halted = "Daily loss limit " + A.dailyLoss + "% reached - auto stopped until tomorrow";
      save();
      return day.halted;
    }
  }
  const age = num(b.age);
  if (!Number.isFinite(age) || age > 1500) return "Market closed or chart data stale";
  if (account.open.length >= A.maxOpen) return "Max open trades reached (" + A.maxOpen + ")";
  if (db.signals.some((s) => s.status === "queued" || s.status === "sent")) return "An order is still being placed";
  if (autoTradesToday() >= A.maxTradesDay) return "Max trades for today reached (" + A.maxTradesDay + ")";
  const recent = db.signals.filter((s) => s.source === "auto" && s.symbol === symbol && s.status !== "failed" && s.status !== "expired").pop();
  if (recent && Date.now() - recent.created < A.cooldownMin * 60000) return "Cooldown after last trade on " + symbol;
  if (day.scans >= A.maxScansDay) return "Daily scan budget used (" + A.maxScansDay + ")";
  if (lastScan[symbol] && Date.now() - lastScan[symbol] < A.scanEveryMin * 60000) return "";   // quiet wait
  if (scanning[symbol]) return "";
  return "GO";
}

function systemPrompt(now) {
  const style = A.mode === "swing"
    ? "SWING/INTRADAY: trade idea lasts hours. Entry timeframe M15, bias from H1 and H4."
    : "SCALPING: trade idea lasts minutes to a couple of hours. Entry timeframe M5 (confirm on M15), bias from H1 and H4.";
  return [
    "You are the auto-trading analyst of DJ Narutto AfriQa Bot. Method: Smart Money Concepts.",
    style,
    "You receive closed OHLC candles (oldest first) for M5, M15, H1, H4 and the live bid/ask. Use ONLY this data. Never invent prices.",
    "Read: higher-timeframe bias, market structure (BOS, CHoCH), liquidity (equal highs/lows, sweeps), points of interest (order block, FVG, supply/demand).",
    now
      ? "ON-DEMAND MODE: the trader pressed Trade NOW and wants a position opened AT MARKET immediately. Pick the side that follows the higher-timeframe (H1/H4) bias, or the M15 structure if H1/H4 disagree. A perfect textbook setup is NOT required, and a pullback is not required. Place the stop beyond the nearest sensible invalidation swing and the take profit at the next liquidity level. Return WAIT only if the market looks closed, the data is unreadable, volatility is abnormal, or you truly cannot choose a side. Use low confidence (40-60) when the setup is average."
      : "IMPORTANT: your order is executed AT MARKET right now. Return BUY or SELL only when a confirmed setup exists at the CURRENT price: a liquidity sweep or POI reaction followed by a CHoCH/BOS on the entry timeframe, with price still close to the POI. If the setup needs a pullback, price has already run, or structure is unclear, return WAIT. WAIT is the right answer most of the time. Do not chase.",
    "Stop loss beyond the invalidation swing and clearly wider than the spread. Take profit at the next liquidity pool. Minimum reward:risk " + A.minRR + ".",
    "Reply with ONE JSON object only, no markdown: {\"signal\":\"BUY|SELL|WAIT\",\"symbol\":\"\",\"entry\":0,\"sl\":0,\"tp\":0,\"confidence\":0-100,\"bias\":\"bullish|bearish|range\",\"reasons\":[\"short\"],\"invalidation\":\"short\"}.",
    "Confidence above 80 is almost never justified. Be honest."
  ].join("\n");
}

function tfBlock(name, raw) {
  const rows = String(raw || "").split(";").filter(Boolean);
  return name + " (" + rows.length + " candles, time|open|high|low|close)\n" + rows.join("\n");
}

async function askClaude(user, now) {
  const r = await fetch(API_URL, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": API_KEY, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({ model: A.model, max_tokens: 1200, system: systemPrompt(now), messages: [{ role: "user", content: user }] }),
    signal: AbortSignal.timeout(60000)
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error((j.error && j.error.message) || ("Anthropic HTTP " + r.status));
  const txt = (j.content || []).map((c) => c.text || "").join("");
  const m = txt.match(/\{[\s\S]*\}/);
  if (!m) throw new Error("AI reply had no JSON");
  return JSON.parse(m[0]);
}

// Decide if the AI answer may become an order. Returns {ok:true,...} or {ok:false,why}
function judge(j, q, minConf) {
  const sig = String(j.signal || "").toUpperCase();
  if (sig !== "BUY" && sig !== "SELL") return { ok: false, why: "AI says WAIT" + (Array.isArray(j.reasons) && j.reasons[0] ? ": " + String(j.reasons[0]).slice(0, 120) : "") };
  const sl = num(j.sl), tp = num(j.tp), conf = num(j.confidence), aiEntry = num(j.entry);
  if (!(sl > 0) || !(tp > 0)) return { ok: false, why: "AI levels unreadable" };
  const price = sig === "BUY" ? q.ask : q.bid;
  const sideOk = sig === "BUY" ? (sl < price && price < tp) : (tp < price && price < sl);
  if (!sideOk) return { ok: false, why: "AI levels on the wrong side of the live price" };
  const risk = Math.abs(price - sl), reward = Math.abs(tp - price);
  if (risk < 3 * q.spread) return { ok: false, why: "Stop is tighter than 3x spread" };
  const rr = reward / risk;
  if (rr < A.minRR) return { ok: false, why: "Reward:risk " + rr.toFixed(2) + " below " + A.minRR };
  const need = minConf === undefined ? A.minConf : minConf;
  if (!(conf >= need)) return { ok: false, why: "Confidence " + (Number.isFinite(conf) ? conf : "?") + " below " + need };
  if (aiEntry > 0 && Math.abs(aiEntry - price) > 0.5 * risk) return { ok: false, why: "Price already moved away from the AI entry" };
  return { ok: true, side: sig, entry: price, sl, tp, rr, conf };
}

async function runAutoScan(symbol, b, force) {
  const q = { bid: num(b.bid), ask: num(b.ask) };
  q.spread = q.ask - q.bid;
  if (!(q.bid > 0) || !(q.ask > 0) || q.spread < 0) throw new Error("bad live price");
  const user = "Symbol: " + symbol + "\nLive bid " + q.bid + " ask " + q.ask + " (spread " + q.spread.toFixed(5) + ")\n\n" +
    [tfBlock("M5", b.c5), tfBlock("M15", b.c15), tfBlock("H1", b.c60), tfBlock("H4", b.c240)].join("\n\n");
  const j = await askClaude(user, !!force);
  const v = judge(j, q, force ? 35 : undefined);
  if (!v.ok) { logAuto(symbol, "WAIT", v.why); return; }
  if (!force && !db.auto.enabled) { logAuto(symbol, "SKIP", "Auto was switched off during the scan"); return; }
  const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
  db.signals.push({ id, symbol, side: v.side, entry: v.entry, sl: v.sl, tp: v.tp, lots: 0, risk: A.risk, source: force ? "now" : "auto",
    status: "queued", created: Date.now(), msg: "AI auto, conf " + v.conf + ", RR " + v.rr.toFixed(2) });
  logAuto(symbol, "TRADE", (force ? "NOW  " : "") + v.side + " queued  entry " + v.entry + "  SL " + v.sl + "  TP " + v.tp + "  RR " + v.rr.toFixed(2) + "  conf " + v.conf,
    { side: v.side, entry: v.entry, sl: v.sl, tp: v.tp });
}

const lastCandles = {};
function onCandles(symbol, b) {
  lastCandles[symbol] = { b, ts: Date.now() };
  const g = gates(symbol, b);
  if (g === "") return { ok: true, scan: false };
  if (g !== "GO") { if (g !== "Auto is OFF") skip(symbol, g); return { ok: true, scan: false, reason: g }; }
  lastSkip[symbol] = "";
  lastScan[symbol] = Date.now();
  scanning[symbol] = true;
  dayRec().scans++;
  save();
  runAutoScan(symbol, b).catch((e) => logAuto(symbol, "ERROR", e.message || e)).then(() => { scanning[symbol] = false; });
  return { ok: true, scan: true };
}

function lossHalt() {
  const day = dayRec();
  if (day.halted) return day.halted;
  if (day.startBalance > 0 && account.equity > 0) {
    const lossPct = (day.startBalance - account.equity) / day.startBalance * 100;
    if (lossPct >= A.dailyLoss) { day.halted = "Daily loss limit " + A.dailyLoss + "% reached - stopped until tomorrow"; save(); return day.halted; }
  }
  return "";
}

// Trade NOW: user pressed the button. One scan per symbol that has fresh candles.
function tradeNow() {
  const started = [], blocked = [];
  if (!API_KEY) return { started, blocked: [{ symbol: "all", why: "Server has no ANTHROPIC_API_KEY" }] };
  const acctAge = account.ts ? Date.now() - account.ts : Infinity;
  if (acctAge > 90000) return { started, blocked: [{ symbol: "all", why: "No fresh account data from the EA (is MT5 open?)" }] };
  const halt = lossHalt();
  if (halt) return { started, blocked: [{ symbol: "all", why: halt }] };
  A.symbols.forEach((symbol) => {
    const c = lastCandles[symbol];
    if (!c || Date.now() - c.ts > 240000) { blocked.push({ symbol, why: "No fresh chart data. Attach the EA to a " + symbol + " chart in MT5." }); return; }
    const age = num(c.b.age);
    if (!Number.isFinite(age) || age > 1500) { blocked.push({ symbol, why: "Market closed or data stale" }); return; }
    if (account.open.some((p) => String(p.symbol || "").toUpperCase().indexOf(symbol) === 0)) { blocked.push({ symbol, why: "A " + symbol + " trade is already open" }); return; }
    if (db.signals.some((x) => (x.status === "queued" || x.status === "sent") && x.symbol === symbol)) { blocked.push({ symbol, why: "An order for " + symbol + " is still being placed" }); return; }
    if (scanning[symbol]) { blocked.push({ symbol, why: "A scan for " + symbol + " is already running" }); return; }
    scanning[symbol] = true;
    started.push(symbol);
    logAuto(symbol, "NOW", "Trade NOW pressed - asking the AI");
    runAutoScan(symbol, c.b, true).catch((e) => logAuto(symbol, "ERROR", e.message || e)).then(() => { scanning[symbol] = false; });
  });
  blocked.forEach((x) => logAuto(x.symbol, "SKIP", "Trade NOW: " + x.why));
  return { started, blocked };
}

function autoStatus() {
  const day = dayRec();
  const lossPct = day.startBalance > 0 && account.equity > 0 ? (day.startBalance - account.equity) / day.startBalance * 100 : 0;
  return {
    enabled: !!db.auto.enabled, hasKey: !!API_KEY, mode: A.mode, model: A.model, symbols: A.symbols,
    limits: { riskPct: A.risk, maxOpen: A.maxOpen, maxTradesDay: A.maxTradesDay, dailyLossPct: A.dailyLoss, minConf: A.minConf, minRR: A.minRR, scanEveryMin: A.scanEveryMin, maxScansDay: A.maxScansDay },
    day: { date: day.date, scans: day.scans, trades: autoTradesToday(), lossPct: Math.round(lossPct * 100) / 100, halted: day.halted || "" },
    eaAgeSec: account.ts ? Math.round((Date.now() - account.ts) / 1000) : null,
    log: db.auto.log.slice(-15).reverse()
  };
}

/* ---------- Auto scan (EA sends chart screenshots, bridge asks Claude) ---------- */
const ANTHROPIC_KEY = process.env.ANTHROPIC_KEY || "";
const ANTHROPIC_URL = process.env.ANTHROPIC_URL || "https://api.anthropic.com/v1/messages";
const MODEL = process.env.MODEL || "claude-sonnet-5-5";
const MAX_SCANS_PER_DAY = parseInt(process.env.MAX_SCANS_PER_DAY || "60", 10);
const MAX_ENTRY_DEV_PCT = parseFloat(process.env.MAX_ENTRY_DEV_PCT || "1.0");
const SCAN_BODY_MAX = 12 * 1024 * 1024;
let scans = [];
let scanDay = "";
let scanCount = 0;

const JSON_SHAPE = 'Reply with ONE JSON object and nothing else, using exactly these keys:\n{"signal":"BUY|SELL|WAIT","symbol":"","timeframe":"","entry":0,"sl":0,"tp":0,"rr":0,"confidence":0,"risk":"LOW|MEDIUM|HIGH","bias":"bullish|bearish|range","structure":"","poi":"","liquidity":"","reasons":[""],"invalidation":"","warnings":[]}';
const SYSTEM = [
  "You are Narutto AfriQa, a disciplined Smart Money Concepts (SMC) chart analyst.",
  "You receive one or more trading chart screenshots. Image 1 is the entry timeframe. Any further images are context timeframes (usually higher).",
  "Method: 1) higher-timeframe bias, 2) market structure (BOS, CHoCH), 3) liquidity (equal highs/lows, sweeps), 4) points of interest (order block, FVG, supply/demand, flip level), 5) require confirmation before an entry, 6) entry from the POI, stop beyond the invalidation swing, target at the next liquidity pool.",
  "STRICT RULES:",
  "- Read the symbol, timeframe and every price ONLY from what is visible in the screenshot (header text and price axis). Never invent or guess levels. Interpolate between axis labels carefully.",
  "- If the chart is unreadable, prices cannot be read, or there is no clean setup, answer signal WAIT with the reason in warnings.",
  "- Minimum reward:risk is 1.5. BUY needs sl < entry < tp. SELL needs tp < entry < sl.",
  "- The order will be sent as a MARKET order at the current price, so entry must be at or very near the current price. If price is not at your zone yet, answer WAIT.",
  "- confidence is 0-100 and must reflect real uncertainty. Do not exceed 85.",
  JSON_SHAPE
].join("\n");
const SCALP_SYSTEM = [
  "You are Narutto AfriQa in SCALPING mode, a disciplined Smart Money Concepts (SMC) scalper.",
  "You receive one or more trading chart screenshots. Image 1 is the entry chart (M1-M15). Any further images are higher-timeframe context that give the bias.",
  "Scalping method: 1) read the higher-timeframe bias, 2) mark session or intraday liquidity (recent highs/lows, equal highs/lows, Asian/London/New York range edges), 3) wait for a liquidity sweep followed by a micro CHoCH or BOS on the entry chart, 4) enter on the retrace into an FVG or order block, 5) put the stop just beyond the sweep or invalidation swing, 6) take profit at the nearest opposing liquidity or prior swing, normally 1R to 2R.",
  "STRICT RULES:",
  "- Read the symbol, timeframe and every price ONLY from what is visible (header text and price axis). Never invent or guess levels.",
  "- Do NOT chase: if the last candle is a large impulsive move already far from the zone, answer WAIT. Do not trade the middle of a range.",
  "- The stop must be wide enough to survive normal spread and noise. Never place it inside obvious wick noise.",
  "- Minimum reward:risk is 1.2. BUY needs sl < entry < tp. SELL needs tp < entry < sl.",
  "- The order will be sent as a MARKET order at the current price, so entry must be at or very near the current price. If price is not at your zone yet, answer WAIT.",
  "- If there is no clean setup or the chart is unreadable, answer WAIT and explain in warnings.",
  "- confidence is 0-100 and must reflect real uncertainty. Do not exceed 80.",
  JSON_SHAPE
].join("\n");

function extractJson(text) {
  const a = text.indexOf("{"), b = text.lastIndexOf("}");
  if (a < 0 || b <= a) throw new Error("AI did not return JSON");
  return JSON.parse(text.slice(a, b + 1));
}

function validateSignal(j, mode, price, spread) {
  const out = {
    signal: String(j.signal || "WAIT").toUpperCase(),
    symbol: String(j.symbol || "").toUpperCase().replace(/[^A-Z0-9._]/g, ""),
    timeframe: String(j.timeframe || "").toUpperCase(),
    entry: Number(j.entry), sl: Number(j.sl), tp: Number(j.tp), rr: 0,
    confidence: Math.max(0, Math.min(100, Number(j.confidence) || 0)),
    risk: String(j.risk || "MEDIUM").toUpperCase(),
    reasons: Array.isArray(j.reasons) ? j.reasons.map(String).slice(0, 4) : [],
    warnings: Array.isArray(j.warnings) ? j.warnings.map(String).slice(0, 4) : []
  };
  const wait = (why) => { out.warnings.push(why); out.signal = "WAIT"; };
  if (out.signal !== "BUY" && out.signal !== "SELL") out.signal = "WAIT";
  if (out.signal !== "WAIT") {
    const nums = [out.entry, out.sl, out.tp].every((n) => Number.isFinite(n) && n > 0);
    const side = out.signal === "BUY" ? (out.sl < out.entry && out.entry < out.tp) : (out.tp < out.entry && out.entry < out.sl);
    if (!nums || !side) wait("Levels failed sanity check");
    else {
      out.rr = Math.abs(out.tp - out.entry) / Math.abs(out.entry - out.sl);
      const minRR = mode === "scalp" ? 1.2 : 1.5;
      if (out.rr < minRR) wait("Reward:risk " + out.rr.toFixed(2) + " below " + minRR);
      else if (spread > 0 && Math.abs(out.entry - out.sl) < 3 * spread) wait("Stop is less than 3x spread");
      else if (price > 0 && Math.abs(out.entry - price) / price * 100 > MAX_ENTRY_DEV_PCT) wait("Entry is far from live price - probable misread");
      else if (price > 0 && Math.abs(out.entry - out.sl) / price * 100 > 3) wait("Stop distance above 3 percent of price - probable misread");
    }
  }
  if (!out.symbol) wait("No symbol read");
  return out;
}

async function runScan(b) {
  const day = new Date().toISOString().slice(0, 10);
  if (day !== scanDay) { scanDay = day; scanCount = 0; }
  if (scanCount >= MAX_SCANS_PER_DAY) return { error: "daily scan cap reached (" + MAX_SCANS_PER_DAY + ")" };
  if (!ANTHROPIC_KEY) return { error: "ANTHROPIC_KEY not set on the bridge" };
  const mode = b.mode === "swing" ? "swing" : "scalp";
  const symbol = String(b.symbol || "").toUpperCase().replace(/[^A-Z0-9._]/g, "");
  const price = num(b.price) || 0, spread = num(b.spread) || 0;
  const tfs = Array.isArray(b.tfs) ? b.tfs.slice(0, 4) : [];
  if (!symbol || !tfs.length) return { error: "need symbol and at least one chart" };
  const content = [];
  tfs.forEach((t, i) => {
    const name = String(t.name || "").replace(/[^A-Za-z0-9]/g, "").slice(0, 4);
    const data = String(t.b64 || "");
    if (!/^[A-Za-z0-9+/=]+$/.test(data) || data.length < 1000) throw new Error("bad image " + (i + 1));
    content.push({ type: "text", text: (i === 0 ? "Image 1 - entry timeframe " : "Image " + (i + 1) + " - context timeframe ") + name + ":" });
    content.push({ type: "image", source: { type: "base64", media_type: "image/png", data } });
  });
  content.push({ type: "text", text: "Symbol: " + symbol + ". Live price now: " + (price || "unknown") + ". Current spread: " + (spread || "unknown") + ". Analyze and return the JSON." });
  scanCount++;
  const r = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({ model: MODEL, max_tokens: 1500, system: mode === "scalp" ? SCALP_SYSTEM : SYSTEM, messages: [{ role: "user", content }] }),
    signal: AbortSignal.timeout(90000)
  });
  const j = await r.json();
  if (!r.ok) return { error: (j.error && j.error.message) || ("Anthropic HTTP " + r.status) };
  const text = (j.content || []).map((c) => c.text || "").join("");
  const sig = validateSignal(extractJson(text), mode, price, spread);
  if (sig.symbol && sig.symbol !== symbol.replace(/[^A-Z0-9]/g, "").replace(/(M|C|PRO|RAW)$/, "") && sig.symbol.slice(0, 6) !== symbol.slice(0, 6)) {
    sig.warnings.push("Chart symbol " + sig.symbol + " differs from " + symbol); sig.signal = "WAIT";
  }
  sig.id = Date.now().toString(36) + Math.random().toString(36).slice(2, 5);
  sig.ts = Date.now(); sig.mode = mode; sig.eaSymbol = symbol;
  scans.push(sig); scans = scans.slice(-100);
  return { sig };
}

function scanLine(res) {
  if (res.error) return "ERROR|" + res.error.replace(/[|\r\n]/g, " ").slice(0, 160);
  const s = res.sig;
  const why = (s.signal === "WAIT" ? (s.warnings[0] || s.reasons[0] || "no setup") : (s.reasons[0] || "setup")).replace(/[|\r\n]/g, " ").slice(0, 140);
  if (s.signal === "WAIT") return ["WAIT", s.id, why].join("|");
  return [s.signal, s.id, s.entry, s.sl, s.tp, s.confidence, s.rr.toFixed(2), why].join("|");
}

const server = http.createServer(async (req, res) => {
  if (req.method === "OPTIONS") return send(res, 204, "");
  const url = new URL(req.url, "http://x");
  const route = url.pathname;

  if (route === "/health") return send(res, 200, { ok: true, time: Date.now() });
  if (req.headers["x-token"] !== TOKEN) return send(res, 401, { error: "bad token" });

  try {
    expireOld();

    if (req.method === "POST" && route === "/signal") {
      const b = parseBody(await readBody(req), req.headers["content-type"]);
      const symbol = String(b.symbol || "").toUpperCase().replace(/[^A-Z0-9._]/g, "");
      const side = String(b.side || "").toUpperCase();
      const entry = num(b.entry), sl = num(b.sl), tp = num(b.tp), lots = num(b.lots);
      if (!symbol || symbol.length > 20) return send(res, 400, { error: "bad symbol" });
      if (side !== "BUY" && side !== "SELL") return send(res, 400, { error: "bad side" });
      if (![entry, sl, tp, lots].every((n) => Number.isFinite(n) && n > 0)) return send(res, 400, { error: "bad numbers" });
      if (lots > MAX_LOTS) return send(res, 400, { error: "lots above bridge cap " + MAX_LOTS });
      const ok = side === "BUY" ? (sl < entry && entry < tp) : (tp < entry && entry < sl);
      if (!ok) return send(res, 400, { error: "SL/TP on wrong side of entry" });
      const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
      db.signals.push({ id, symbol, side, entry, sl, tp, lots, status: "queued", created: Date.now(), msg: "" });
      save();
      return send(res, 200, { id, status: "queued" });
    }

    if (req.method === "POST" && route === "/scan") {
      let b;
      try { b = JSON.parse(await readBody(req, SCAN_BODY_MAX)); } catch (e) { return send(res, 400, "ERROR|bad request body", "text/plain"); }
      let out;
      try { out = await runScan(b); } catch (e) { out = { error: String(e.message || e) }; }
      return send(res, 200, scanLine(out), "text/plain");
    }

    if (req.method === "GET" && route === "/scans") {
      return send(res, 200, scans.slice(-30).reverse().map((s) => ({ id: s.id, ts: s.ts, mode: s.mode, symbol: s.symbol, timeframe: s.timeframe, signal: s.signal, entry: s.entry, sl: s.sl, tp: s.tp, rr: s.rr, confidence: s.confidence, note: (s.warnings[0] || s.reasons[0] || "") })));
    }

    if (req.method === "GET" && route === "/pending") {
      const s = db.signals.find((x) => x.status === "queued");
      if (!s) return send(res, 200, "", "text/plain");
      s.status = "sent";
      save();
      const f = [s.id, s.symbol, s.side, s.entry, s.sl, s.tp, s.lots];
      if (s.source === "auto" || s.source === "now") f.push(s.risk);          // 8th field: risk % (EA sizes the lots)
      return send(res, 200, f.join("|"), "text/plain");
    }

    if (req.method === "POST" && route === "/candles") {
      const b = parseBody(await readBody(req, 300000), req.headers["content-type"]);
      const symbol = String(b.symbol || "").toUpperCase().replace(/[^A-Z0-9._]/g, "");
      if (!symbol) return send(res, 400, { error: "bad symbol" });
      return send(res, 200, onCandles(symbol, b));
    }

    if (req.method === "POST" && route === "/trade-now") return send(res, 200, tradeNow());

    if (req.method === "GET" && route === "/auto") return send(res, 200, autoStatus());

    if (req.method === "POST" && route === "/auto") {
      const b = parseBody(await readBody(req), req.headers["content-type"]);
      if (String(b.panic) === "1") {                     // kill switch: off + cancel anything waiting
        db.auto.enabled = false;
        db.signals.forEach((x) => { if (x.status === "queued") { x.status = "cancelled"; x.msg = "Cancelled by STOP"; } });
        logAuto("", "STOP", "Auto switched off (STOP pressed)");
      } else if (b.enabled !== undefined) {
        const on = String(b.enabled) === "1" || String(b.enabled) === "true";
        if (on && !API_KEY) return send(res, 400, { error: "Server has no ANTHROPIC_API_KEY - add it on Render first" });
        db.auto.enabled = on;
        if (on) Object.keys(lastSkip).forEach((k) => { lastSkip[k] = ""; });
        logAuto("", on ? "ON" : "OFF", "Auto switched " + (on ? "ON" : "OFF") + " from the app");
      }
      return send(res, 200, autoStatus());
    }

    if (req.method === "POST" && route === "/report") {
      const b = parseBody(await readBody(req), req.headers["content-type"]);
      const s = db.signals.find((x) => x.id === b.id);
      if (!s) return send(res, 404, { error: "unknown id" });
      s.status = b.status === "filled" ? "filled" : "failed";
      s.ticket = b.ticket || "";
      s.price = num(b.price) || 0;
      s.msg = String(b.msg || "").slice(0, 200);
      s.done = Date.now();
      save();
      return send(res, 200, { ok: true });
    }

    if (req.method === "GET" && route.startsWith("/signal/")) {
      const s = db.signals.find((x) => x.id === route.slice(8));
      return s ? send(res, 200, s) : send(res, 404, { error: "unknown id" });
    }

    if (req.method === "POST" && route === "/positions") {
      const b = parseBody(await readBody(req), req.headers["content-type"]);
      const rows = (s) => String(s || "").split(";").filter(Boolean).map((r) => r.split("|"));
      account = {
        ts: Date.now(),
        balance: num(b.balance) || 0, equity: num(b.equity) || 0, currency: String(b.currency || "").slice(0, 8),
        open: rows(b.open).slice(0, 30).map((p) => ({ ticket: p[0], symbol: p[1], side: p[2], lots: num(p[3]), open: num(p[4]), sl: num(p[5]), tp: num(p[6]), price: num(p[7]), profit: num(p[8]) })),
        closed: rows(b.closed).slice(0, 20).map((p) => ({ ticket: p[0], symbol: p[1], side: p[2], lots: num(p[3]), price: num(p[4]), profit: num(p[5]), reason: p[6], time: p[7] }))
      };
      return send(res, 200, { ok: true });
    }

    if (req.method === "GET" && route === "/positions") {
      return send(res, 200, Object.assign({ age: account.ts ? Date.now() - account.ts : null }, account));
    }

    if (req.method === "GET" && route === "/trades") {
      return send(res, 200, db.signals.slice(-30).reverse());
    }

    return send(res, 404, { error: "not found" });
  } catch (e) {
    return send(res, 400, { error: String(e.message || e) });
  }
});

server.listen(PORT, () => console.log("Narutto bridge listening on :" + PORT));
