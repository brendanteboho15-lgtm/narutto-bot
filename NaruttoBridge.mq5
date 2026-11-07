//+------------------------------------------------------------------+
//| NaruttoBridge.mq5                                                |
//| Narutto AfriQa Bot - executes signals queued on the bridge       |
//| L99 standard: ASCII only, handle-free, no chart object clutter   |
//+------------------------------------------------------------------+
#property copyright "Narutto AfriQa Bot"
#property version   "1.40"
#property strict

#include <Trade/Trade.mqh>

input string InpBridgeUrl       = "https://your-bridge.example.com"; // Bridge base URL (no trailing slash)
input string InpToken           = "";        // Bridge token
input int    InpPollSeconds     = 3;         // Poll interval (seconds)
input long   InpMagic           = 990001;    // Magic number
input string InpSymbolSuffix    = "";        // Broker symbol suffix, e.g. m (leave empty if none)
input double InpMaxSpreadPoints = 3000.0;      // Max spread in points (0 = no check)
input double InpMaxDriftPoints  = 20000.0;     // Max distance from signal entry in points (0 = no check)
input double InpMaxLots         = 1.0;       // Hard lot cap
input int    InpSlippagePoints  = 30;        // Max slippage in points
input bool   InpAllowTrading    = true;      // Master switch
input bool   InpAutoScan        = true;      // Send candles to the bridge for AI auto-trading
input int    InpBarsM5          = 80;        // Candles sent: M5
input int    InpBarsM15         = 100;        // Candles sent: M15
input int    InpBarsH1          = 120;        // Candles sent: H1
input int    InpBarsH4          = 80;        // Candles sent: H4
input int    InpMaxPositions    = 3;         // Hard cap on open positions with this magic (0 = no cap)
input double InpMinLotRiskCapPct = 0.0;      // Small accounts: if the risk-sized lot is below the broker minimum, trade the minimum lot only when it risks at most this % of balance (0 = off, max 3)

input double InpBreakEvenAtR    = 1.0;       // Move stop to break-even once profit reaches this many R (0 = off). 1R = the original stop distance
input double InpPartialPct      = 50.0;      // Close this % of the trade at InpPartialAtR (0 = off; skipped if lot is too small to split)
input double InpPartialAtR      = 1.0;       // Partial close target in R
input double InpTrailAtR        = 1.5;       // Start trailing the stop at this many R (0 = off)
input double InpTrailDistR      = 1.0;       // Trailing stop distance in R

input bool   InpMomentum        = false;     // MOMENTUM SCALPER: trade strong candle breakouts on THIS chart without the AI (OFF by default)
input ENUM_TIMEFRAMES InpMomTF  = PERIOD_M5; // Momentum: candle timeframe
input int    InpMomLookback     = 15;        // Momentum: candle must close beyond the high/low of this many candles
input double InpMomBodyATR      = 0.8;       // Momentum: candle body must be at least this many ATR (filters weak candles)
input double InpMomSLATR        = 1.0;       // Momentum: stop loss = this many ATR
input double InpMomRR           = 1.5;       // Momentum: take profit = this many times the stop
input double InpMomLots         = 0.01;      // Momentum: fixed lot size
input int    InpMomMaxLossStreak = 3;        // Momentum: pause after this many losing closes in a row (0 = off)
input int    InpMomPauseMin     = 60;        // Momentum: pause length in minutes
input bool   InpMomGoldHours    = true;      // Momentum: gold only trades 06:00-20:00 UTC

CTrade g_trade;
datetime g_lastMomBar = 0;
string g_handled[];
int    g_failStreak = 0;
datetime g_lastBar  = 0;

//+------------------------------------------------------------------+
bool WasHandled(const string id)
{
   int n = ArraySize(g_handled);
   for(int i = 0; i < n; i++)
      if(g_handled[i] == id)
         return(true);
   return(false);
}

void MarkHandled(const string id)
{
   int n = ArraySize(g_handled);
   if(n >= 100)
   {
      for(int i = 1; i < n; i++)
         g_handled[i - 1] = g_handled[i];
      n--;
      ArrayResize(g_handled, n);
   }
   ArrayResize(g_handled, n + 1);
   g_handled[n] = id;
}

//+------------------------------------------------------------------+
//| HTTP helper: returns HTTP status (or -1 on WebRequest failure)   |
//+------------------------------------------------------------------+
int Http(const string method, const string path, const string body, string &response)
{
   char   data[];
   char   result[];
   string resHeaders;
   string headers = "X-Token: " + InpToken + "\r\n";
   if(method == "POST")
   {
      headers += "Content-Type: application/x-www-form-urlencoded\r\n";
      StringToCharArray(body, data, 0, StringLen(body), CP_UTF8);
   }
   ResetLastError();
   int code = WebRequest(method, InpBridgeUrl + path, headers, 5000, data, result, resHeaders);
   if(code == -1)
   {
      response = "WebRequest error " + IntegerToString(GetLastError());
      return(-1);
   }
   response = CharArrayToString(result, 0, ArraySize(result), CP_UTF8);
   return(code);
}

string UrlEncode(const string s)
{
   string out = "";
   uchar  b[];
   int n = StringToCharArray(s, b, 0, StringLen(s), CP_UTF8);
   for(int i = 0; i < n; i++)
   {
      uchar c = b[i];
      if((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '-' || c == '_' || c == '.')
         out += CharToString(c);
      else
         out += StringFormat("%%%02X", c);
   }
   return(out);
}

void Report(const string id, const bool ok, const ulong ticket, const double price, const string msg)
{
   string body = "id=" + UrlEncode(id)
               + "&status=" + (ok ? "filled" : "failed")
               + "&ticket=" + IntegerToString((long)ticket)
               + "&price=" + DoubleToString(price, 5)
               + "&msg=" + UrlEncode(msg);
   string resp;
   Http("POST", "/report", body, resp);
}

//+------------------------------------------------------------------+
int CountMyPositions()
{
   int n = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic)
         n++;
   }
   return(n);
}

//+------------------------------------------------------------------+
//| Validate and execute a signal                                    |
//+------------------------------------------------------------------+
bool Execute(const string sym, const string side, const double entry, const double sl,
             const double tp, const double lotsIn, const double riskPct, ulong &ticket, double &fill, string &msg)
{
   ticket = 0;
   fill   = 0.0;

   if(!InpAllowTrading)
   {
      msg = "Trading disabled in EA inputs";
      return(false);
   }
   if(!SymbolSelect(sym, true))
   {
      msg = "Symbol not found: " + sym;
      return(false);
   }
   if(InpMaxPositions > 0 && CountMyPositions() >= InpMaxPositions)
   {
      msg = "EA position cap reached (" + IntegerToString(InpMaxPositions) + ")";
      return(false);
   }

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
   {
      msg = "No price for " + sym;
      return(false);
   }

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(point <= 0.0)
   {
      msg = "Bad point size";
      return(false);
   }

   bool isBuy = (side == "BUY");
   if(!isBuy && side != "SELL")
   {
      msg = "Bad side";
      return(false);
   }

   double price  = isBuy ? tick.ask : tick.bid;
   double spread = (tick.ask - tick.bid) / point;

   if(InpMaxSpreadPoints > 0.0 && spread > InpMaxSpreadPoints)
   {
      msg = "Spread too high: " + DoubleToString(spread, 0) + " pts";
      return(false);
   }
   if(InpMaxDriftPoints > 0.0 && MathAbs(price - entry) / point > InpMaxDriftPoints)
   {
      msg = "Price moved away from entry: " + DoubleToString(MathAbs(price - entry) / point, 0) + " pts";
      return(false);
   }

   if(isBuy && !(sl < price && price < tp))
   {
      msg = "BUY needs SL < price < TP";
      return(false);
   }
   if(!isBuy && !(tp < price && price < sl))
   {
      msg = "SELL needs TP < price < SL";
      return(false);
   }

   double stopsLevel = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   if(MathAbs(price - sl) < stopsLevel || MathAbs(price - tp) < stopsLevel)
   {
      msg = "SL/TP inside broker stop level";
      return(false);
   }

   double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0.0)
      stepLot = 0.01;
   double want = lotsIn;
   double lossPerLot = 0.0;
   if(want <= 0.0 && riskPct > 0.0)
   {
      double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickVal <= 0.0)
      {
         msg = "No tick value for risk sizing";
         return(false);
      }
      lossPerLot = MathAbs(price - sl) / tickSize * tickVal;
      if(lossPerLot <= 0.0)
      {
         msg = "Bad stop distance for risk sizing";
         return(false);
      }
      want = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0 / lossPerLot;
   }
   if(want <= 0.0)
   {
      msg = "No lot size";
      return(false);
   }
   double lots = MathMin(want, InpMaxLots);
   lots = MathMin(lots, maxLot);
   lots = MathFloor(lots / stepLot + 0.0000001) * stepLot;
   if(lots < minLot)
   {
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      double minRisk = 0.0;
      if(lossPerLot > 0.0 && bal > 0.0)
         minRisk = minLot * lossPerLot / bal * 100.0;
      double cap = MathMin(InpMinLotRiskCapPct, 3.0);
      if(cap > 0.0 && minRisk > 0.0 && minRisk <= cap)
         lots = minLot;
      else
      {
         msg = "Lot below broker minimum " + DoubleToString(minLot, 2) + ": the minimum lot would risk "
             + DoubleToString(minRisk, 2) + "% of balance (limit " + DoubleToString(riskPct, 2)
             + "%, cap " + DoubleToString(cap, 2) + "%)";
         return(false);
      }
   }
   lots = NormalizeDouble(lots, 2);

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double nsl = NormalizeDouble(sl, digits);
   double ntp = NormalizeDouble(tp, digits);

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);

   bool sent = isBuy ? g_trade.Buy(lots, sym, 0.0, nsl, ntp, "NaruttoBot")
                     : g_trade.Sell(lots, sym, 0.0, nsl, ntp, "NaruttoBot");
   uint rc = g_trade.ResultRetcode();
   if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED))
   {
      msg = "Order failed: " + g_trade.ResultRetcodeDescription() + " (" + IntegerToString((int)rc) + ")";
      return(false);
   }

   ticket = g_trade.ResultOrder();
   fill   = g_trade.ResultPrice();
   msg    = "Filled " + DoubleToString(lots, 2) + " lots";
   return(true);
}

//+------------------------------------------------------------------+
//| Send open positions, closed deals and account numbers            |
//+------------------------------------------------------------------+
void SendPositions()
{
   string openRows = "";
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      string side = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      string row = IntegerToString((long)tk) + "|" + PositionGetString(POSITION_SYMBOL) + "|" + side
                 + "|" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2)
                 + "|" + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 5)
                 + "|" + DoubleToString(PositionGetDouble(POSITION_SL), 5)
                 + "|" + DoubleToString(PositionGetDouble(POSITION_TP), 5)
                 + "|" + DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT), 5)
                 + "|" + DoubleToString(pl, 2);
      if(openRows != "")
         openRows += ";";
      openRows += row;
   }

   string closedRows = "";
   if(HistorySelect(TimeCurrent() - 7 * 86400, TimeCurrent() + 60))
   {
      int n = HistoryDealsTotal();
      int cnt = 0;
      for(int i = n - 1; i >= 0 && cnt < 20; i--)
      {
         ulong dt = HistoryDealGetTicket(i);
         if(dt == 0)
            continue;
         if(HistoryDealGetInteger(dt, DEAL_MAGIC) != InpMagic)
            continue;
         if(HistoryDealGetInteger(dt, DEAL_ENTRY) != DEAL_ENTRY_OUT)
            continue;
         string side = (HistoryDealGetInteger(dt, DEAL_TYPE) == DEAL_TYPE_SELL) ? "BUY" : "SELL";
         double pl = HistoryDealGetDouble(dt, DEAL_PROFIT) + HistoryDealGetDouble(dt, DEAL_SWAP)
                   + HistoryDealGetDouble(dt, DEAL_COMMISSION);
         long why = HistoryDealGetInteger(dt, DEAL_REASON);
         string rs = "MANUAL";
         if(why == DEAL_REASON_TP)
            rs = "TP";
         else if(why == DEAL_REASON_SL)
            rs = "SL";
         string row = IntegerToString(HistoryDealGetInteger(dt, DEAL_POSITION_ID)) + "|" + HistoryDealGetString(dt, DEAL_SYMBOL)
                    + "|" + side + "|" + DoubleToString(HistoryDealGetDouble(dt, DEAL_VOLUME), 2)
                    + "|" + DoubleToString(HistoryDealGetDouble(dt, DEAL_PRICE), 5)
                    + "|" + DoubleToString(pl, 2) + "|" + rs
                    + "|" + TimeToString((datetime)HistoryDealGetInteger(dt, DEAL_TIME), TIME_DATE | TIME_MINUTES)
                    + "|" + (GlobalVariableCheck("NBM_" + IntegerToString(HistoryDealGetInteger(dt, DEAL_POSITION_ID))) ? "MOM" : "AI");
         if(closedRows != "")
            closedRows += ";";
         closedRows += row;
         cnt++;
      }
   }

   string body = "open=" + UrlEncode(openRows) + "&closed=" + UrlEncode(closedRows)
               + "&balance=" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2)
               + "&equity=" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2)
               + "&currency=" + UrlEncode(AccountInfoString(ACCOUNT_CURRENCY))
               + "&login=" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN));
   string resp;
   Http("POST", "/positions", body, resp);
}

//+------------------------------------------------------------------+
//| Closed candles, oldest first: "MM.DD HH:MI|o|h|l|c;..."          |
//+------------------------------------------------------------------+
string Candles(const string sym, const ENUM_TIMEFRAMES tf, const int count)
{
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int got = CopyRates(sym, tf, 1, count, r);
   if(got <= 0)
      return("");
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   string out = "";
   for(int i = 0; i < got; i++)
   {
      string t = StringSubstr(TimeToString(r[i].time, TIME_DATE | TIME_MINUTES), 5);
      if(i > 0)
         out += ";";
      out += t + "|" + DoubleToString(r[i].open, digits) + "|" + DoubleToString(r[i].high, digits)
           + "|" + DoubleToString(r[i].low, digits) + "|" + DoubleToString(r[i].close, digits);
   }
   return(out);
}

void SendCandles()
{
   string sym = _Symbol;
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
      return;
   MqlRates last[];
   if(CopyRates(sym, PERIOD_M5, 1, 1, last) != 1)
      return;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   string base = sym;
   int ls = StringLen(InpSymbolSuffix);
   if(ls > 0 && StringLen(sym) > ls && StringSubstr(sym, StringLen(sym) - ls) == InpSymbolSuffix)
      base = StringSubstr(sym, 0, StringLen(sym) - ls);

   string body = "symbol=" + UrlEncode(base)
               + "&bid=" + DoubleToString(tick.bid, digits)
               + "&ask=" + DoubleToString(tick.ask, digits)
               + "&age=" + IntegerToString((long)(TimeCurrent() - last[0].time))
               + "&c5=" + UrlEncode(Candles(sym, PERIOD_M5, InpBarsM5))
               + "&c15=" + UrlEncode(Candles(sym, PERIOD_M15, InpBarsM15))
               + "&c60=" + UrlEncode(Candles(sym, PERIOD_H1, InpBarsH1))
               + "&c240=" + UrlEncode(Candles(sym, PERIOD_H4, InpBarsH4));
   string resp;
   int code = Http("POST", "/candles", body, resp);
   if(code != 200)
      Print("Narutto: candles upload failed (", code, ") ", resp);
}

//+------------------------------------------------------------------+
void Poll()
{
   string resp;
   int code = Http("GET", "/pending", "", resp);
   if(code != 200)
   {
      g_failStreak++;
      Comment("Narutto Bridge: OFFLINE (", code, ") ", resp);
      return;
   }
   g_failStreak = 0;
   Comment("Narutto Bridge: ONLINE  trading=", (InpAllowTrading ? "ON" : "OFF"), "  candles=", (InpAutoScan ? "ON" : "OFF"));

   StringTrimLeft(resp);
   StringTrimRight(resp);
   if(StringLen(resp) == 0)
   {
      SendPositions();
      return;
   }

   string p[];
   int np = StringSplit(resp, '|', p);
   if(np != 7 && np != 8)
   {
      Print("Narutto: malformed signal: ", resp);
      return;
   }

   string id   = p[0];
   if(WasHandled(id))
      return;
   MarkHandled(id);

   string sym   = p[1] + InpSymbolSuffix;
   string side  = p[2];
   double entry = StringToDouble(p[3]);
   double sl    = StringToDouble(p[4]);
   double tp    = StringToDouble(p[5]);
   double lots  = StringToDouble(p[6]);
   double riskP = (np == 8) ? StringToDouble(p[7]) : 0.0;

   ulong  ticket;
   double fill;
   string msg;
   bool ok = Execute(sym, side, entry, sl, tp, lots, riskP, ticket, fill, msg);
   Print("Narutto: ", id, " ", sym, " ", side, " -> ", msg);
   Report(id, ok, ticket, fill, msg);
   SendPositions();
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(InpToken) < 8)
   {
      Print("Narutto: set InpToken (min 8 chars)");
      return(INIT_PARAMETERS_INCORRECT);
   }
   int sec = (int)MathMax(1, InpPollSeconds);
   EventSetTimer(sec);
   Comment("Narutto Bridge: starting...");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}

//+------------------------------------------------------------------+
//| Protect open trades: partial close, break-even, trailing stop     |
//+------------------------------------------------------------------+
void ManagePositions()
{
   if(InpBreakEvenAtR <= 0.0 && InpPartialPct <= 0.0 && InpTrailAtR <= 0.0)
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      string sym  = PositionGetString(POSITION_SYMBOL);
      long   pid  = PositionGetInteger(POSITION_IDENTIFIER);
      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      string kr = "NBR_" + IntegerToString(pid);
      string kp = "NBP_" + IntegerToString(pid);
      double r = 0.0;
      if(GlobalVariableCheck(kr))
         r = GlobalVariableGet(kr);
      else if(sl > 0.0)
      {
         r = MathAbs(open - sl);          // first time we see it: the stop is still the original one
         GlobalVariableSet(kr, r);
      }
      if(r <= 0.0)
         continue;
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(bid <= 0.0 || ask <= 0.0 || point <= 0.0)
         continue;
      double gain = isBuy ? (bid - open) : (open - ask);
      double minDist = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point + (ask - bid);
      g_trade.SetExpertMagicNumber(InpMagic);

      // 1) partial close
      if(InpPartialPct > 0.0 && !GlobalVariableCheck(kp) && gain >= InpPartialAtR * r)
      {
         double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
         double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
         if(step <= 0.0) step = 0.01;
         double part = MathFloor(vol * InpPartialPct / 100.0 / step) * step;
         if(part >= minLot && (vol - part) >= minLot)
         {
            if(g_trade.PositionClosePartial(tk, NormalizeDouble(part, 2)))
               Print("Partial close ", sym, " ", DoubleToString(part, 2), " lots at ", DoubleToString(InpPartialAtR, 1), "R");
            GlobalVariableSet(kp, 1.0);
            continue;                       // position changed - handle the rest next timer
         }
         GlobalVariableSet(kp, 1.0);         // too small to split: skip partial for this trade
      }

      // 2) break-even, 3) trailing: the stop only ever moves in the trade's favour
      double newSl = 0.0;
      if(InpBreakEvenAtR > 0.0 && gain >= InpBreakEvenAtR * r)
         newSl = isBuy ? open + (ask - bid) : open - (ask - bid);
      if(InpTrailAtR > 0.0 && gain >= InpTrailAtR * r)
      {
         double t = isBuy ? bid - InpTrailDistR * r : ask + InpTrailDistR * r;
         if(newSl == 0.0 || (isBuy && t > newSl) || (!isBuy && t < newSl))
            newSl = t;
      }
      if(newSl <= 0.0)
         continue;
      newSl = NormalizeDouble(newSl, digits);
      bool better = (sl <= 0.0) || (isBuy ? newSl > sl + point : newSl < sl - point);
      bool legal  = isBuy ? (bid - newSl >= minDist) : (newSl - ask >= minDist);
      if(better && legal)
         g_trade.PositionModify(tk, newSl, tp);
   }
}

//+------------------------------------------------------------------+
//| Momentum scalper helpers                                          |
//+------------------------------------------------------------------+
bool MomEma(const ENUM_TIMEFRAMES tf, const int period, double &out)
{
   int n = period * 4 + 2;
   double c[];
   ArraySetAsSeries(c, false);
   if(CopyClose(_Symbol, tf, 0, n, c) != n)
      return false;
   double k = 2.0 / (period + 1);
   double e = c[0];
   for(int i = 1; i < n - 1; i++)      // n-1 is the still-forming bar: ignored
      e = c[i] * k + e * (1.0 - k);
   out = e;
   return true;
}

int MomTrend(const ENUM_TIMEFRAMES tf)
{
   double e20, e50;
   if(!MomEma(tf, 20, e20) || !MomEma(tf, 50, e50))
      return 0;
   double px = iClose(_Symbol, tf, 1);
   if(e20 > e50 && px > e50) return 1;
   if(e20 < e50 && px < e50) return -1;
   return 0;
}

bool MomPaused()
{
   if(InpMomMaxLossStreak <= 0)
      return false;
   if(!HistorySelect(TimeCurrent() - 2 * 86400, TimeCurrent() + 60))
      return false;
   int streak = 0;
   datetime lastLoss = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong dt = HistoryDealGetTicket(i);
      if(dt == 0 || HistoryDealGetInteger(dt, DEAL_MAGIC) != InpMagic)
         continue;
      if(HistoryDealGetInteger(dt, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      double p = HistoryDealGetDouble(dt, DEAL_PROFIT) + HistoryDealGetDouble(dt, DEAL_SWAP) + HistoryDealGetDouble(dt, DEAL_COMMISSION);
      if(p < 0.0)
      {
         streak++;
         if(lastLoss == 0)
            lastLoss = (datetime)HistoryDealGetInteger(dt, DEAL_TIME);
      }
      else
         break;
   }
   return (streak >= InpMomMaxLossStreak && lastLoss > 0 && (TimeCurrent() - lastLoss) < InpMomPauseMin * 60);
}

void MomentumTick()
{
   datetime cur = iTime(_Symbol, InpMomTF, 0);
   if(cur == 0 || cur == g_lastMomBar)
      return;
   g_lastMomBar = cur;                       // one decision per new candle

   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
      return;
   if(InpMomGoldHours && StringFind(_Symbol, "XAU") == 0)
   {
      MqlDateTime t;
      TimeToStruct(TimeGMT(), t);
      if(t.hour < 6 || t.hour >= 20)
         return;
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--)        // one momentum trade per symbol at a time
   {
      ulong tk = PositionGetTicket(i);
      if(tk != 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic && PositionGetString(POSITION_SYMBOL) == _Symbol)
         return;
   }
   if(InpMaxPositions > 0 && CountMyPositions() >= InpMaxPositions)
      return;
   if(MomPaused())
      return;

   int look = InpMomLookback;
   if(look < 3) look = 3;
   int need = MathMax(look, 14) + 4;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   if(CopyRates(_Symbol, InpMomTF, 0, need, r) != need)
      return;
   int last = need - 2;                      // last CLOSED candle; need-1 is forming
   double atr = 0.0;
   for(int i = last - 13; i <= last; i++)
      atr += MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
   atr /= 14.0;
   if(atr <= 0.0)
      return;
   double hh = -DBL_MAX, ll = DBL_MAX;
   for(int i = last - look; i < last; i++)
   {
      hh = MathMax(hh, r[i].high);
      ll = MathMin(ll, r[i].low);
   }
   double body = MathAbs(r[last].close - r[last].open);
   double rng  = r[last].high - r[last].low;
   if(body < InpMomBodyATR * atr || rng <= 0.0)
      return;
   int dir = 0;
   if(r[last].close > hh && r[last].close > r[last].open && (r[last].close - r[last].low) / rng >= 0.7)
      dir = 1;
   else if(r[last].close < ll && r[last].close < r[last].open && (r[last].high - r[last].close) / rng >= 0.7)
      dir = -1;
   if(dir == 0)
      return;
   if(MomTrend(PERIOD_M15) != dir || MomTrend(PERIOD_H1) != dir)
      return;                                // never fight the higher timeframes

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(point <= 0.0 || ask <= 0.0 || bid <= 0.0)
      return;
   double spread = ask - bid;
   if(InpMaxSpreadPoints > 0.0 && spread / point > InpMaxSpreadPoints)
      return;
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double slDist = MathMax(atr * InpMomSLATR, minStop * 1.5 + spread);
   if(spread > 0.25 * slDist)
      return;                                // costs would eat the trade
   double entry = (dir == 1) ? ask : bid;
   double sl = (dir == 1) ? entry - slDist : entry + slDist;
   double tp = (dir == 1) ? entry + slDist * InpMomRR : entry - slDist * InpMomRR;
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(step <= 0.0) step = 0.01;
   double lots = MathFloor(InpMomLots / step + 1e-9) * step;
   if(lots < minLot) lots = minLot;
   if(InpMaxLots > 0.0 && lots > InpMaxLots) lots = InpMaxLots;
   lots = NormalizeDouble(lots, 2);

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   bool ok = (dir == 1) ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, "NaruttoMom")
                        : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, "NaruttoMom");
   if(!ok)
   {
      Print("Momentum order failed: ", g_trade.ResultRetcodeDescription(), " (", (int)g_trade.ResultRetcode(), ")");
      return;
   }
   ulong tk = g_trade.ResultOrder();
   if((tk != 0 && PositionSelectByTicket(tk)) || PositionSelect(_Symbol))
      GlobalVariableSet("NBM_" + IntegerToString(PositionGetInteger(POSITION_IDENTIFIER)), 1.0);
   Print("Momentum ", (dir == 1 ? "BUY " : "SELL "), _Symbol, " ", DoubleToString(lots, 2), " lots SL ", DoubleToString(sl, digits), " TP ", DoubleToString(tp, digits));
}

void OnTimer()
{
   Poll();
   ManagePositions();
   if(InpMomentum && InpAllowTrading)
      MomentumTick();
   if(InpAutoScan && InpAllowTrading)
   {
      datetime cur = iTime(_Symbol, PERIOD_M5, 0);
      if(cur != 0 && cur != g_lastBar)
      {
         g_lastBar = cur;
         SendCandles();
      }
   }
}

void OnTick()
{
}
//+------------------------------------------------------------------+
