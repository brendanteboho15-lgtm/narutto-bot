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

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => { data += c; if (data.length > 20000) { reject(new Error("too large")); req.destroy(); } });
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

    if (req.method === "GET" && route === "/pending") {
      const s = db.signals.find((x) => x.status === "queued");
      if (!s) return send(res, 200, "", "text/plain");
      s.status = "sent";
      save();
      return send(res, 200, [s.id, s.symbol, s.side, s.entry, s.sl, s.tp, s.lots].join("|"), "text/plain");
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
