//+------------------------------------------------------------------+
//| NaruttoBridge.mq5                                                |
//| Narutto AfriQa Bot - executes signals queued on the bridge       |
//| L99 standard: ASCII only, handle-free, no chart object clutter   |
//+------------------------------------------------------------------+
#property copyright "Narutto AfriQa Bot"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input string InpBridgeUrl       = "https://your-bridge.example.com"; // Bridge base URL (no trailing slash)
input string InpToken           = "";        // Bridge token
input int    InpPollSeconds     = 3;         // Poll interval (seconds)
input long   InpMagic           = 990001;    // Magic number
input string InpSymbolSuffix    = "";        // Broker symbol suffix, e.g. m (leave empty if none)
input double InpMaxSpreadPoints = 80.0;      // Max spread in points (0 = no check)
input double InpMaxDriftPoints  = 500.0;     // Max distance from signal entry in points (0 = no check)
input double InpMaxLots         = 1.0;       // Hard lot cap
input int    InpSlippagePoints  = 30;        // Max slippage in points
input bool   InpAllowTrading    = true;      // Master switch

CTrade g_trade;
string g_handled[];
int    g_failStreak = 0;

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
//| Validate and execute a signal                                    |
//+------------------------------------------------------------------+
bool Execute(const string sym, const string side, const double entry, const double sl,
             const double tp, const double lotsIn, ulong &ticket, double &fill, string &msg)
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
   double lots = MathMin(lotsIn, InpMaxLots);
   lots = MathMin(lots, maxLot);
   lots = MathFloor(lots / stepLot + 0.0000001) * stepLot;
   if(lots < minLot)
   {
      msg = "Lot below broker minimum " + DoubleToString(minLot, 2);
      return(false);
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
                    + "|" + TimeToString((datetime)HistoryDealGetInteger(dt, DEAL_TIME), TIME_DATE | TIME_MINUTES);
         if(closedRows != "")
            closedRows += ";";
         closedRows += row;
         cnt++;
      }
   }

   string body = "open=" + UrlEncode(openRows) + "&closed=" + UrlEncode(closedRows)
               + "&balance=" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2)
               + "&equity=" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2)
               + "&currency=" + UrlEncode(AccountInfoString(ACCOUNT_CURRENCY));
   string resp;
   Http("POST", "/positions", body, resp);
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
   Comment("Narutto Bridge: ONLINE  trading=", (InpAllowTrading ? "ON" : "OFF"));

   StringTrimLeft(resp);
   StringTrimRight(resp);
   if(StringLen(resp) == 0)
   {
      SendPositions();
      return;
   }

   string p[];
   if(StringSplit(resp, '|', p) != 7)
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

   ulong  ticket;
   double fill;
   string msg;
   bool ok = Execute(sym, side, entry, sl, tp, lots, ticket, fill, msg);
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

void OnTimer()
{
   Poll();
}

void OnTick()
{
}
//+------------------------------------------------------------------+
