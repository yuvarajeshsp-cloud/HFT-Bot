//+------------------------------------------------------------------+
//|                                              FibBreakoutEA.mq5   |
//|         MT5 XAUUSD Fibonacci Breakout + Averaging Expert Advisor |
//+------------------------------------------------------------------+
#property copyright "FibBreakoutEA"
#property version   "1.02"
#property strict
#property description "Breakout (BUY STOP / SELL STOP) entry with Fibonacci-lot averaging,"
#property description "virtual weighted-average basket take-profit, and layered risk controls."
#property description "Primary target symbol: XAUUSD. Designed for retail hedging accounts."

#include <Trade/Trade.mqh>

//======================================================================
// ENUMS
//======================================================================
enum EAState
{
   STATE_IDLE,
   STATE_WAITING_FOR_BREAKOUT,
   STATE_BUY_ACTIVE,
   STATE_SELL_ACTIVE,
   STATE_TP_CLOSING,
   STATE_COOLDOWN,
   STATE_RISK_STOP,
   STATE_EMERGENCY_BOTH_SIDES,
   STATE_ERROR
};

enum ENUM_BASKET_DIRECTION
{
   BASKET_NONE = 0,
   BASKET_BUY  = 1,
   BASKET_SELL = 2
};

enum ENUM_PROFIT_MODE
{
   PROFIT_MODE_CURRENCY            = 0, // Currency
   PROFIT_MODE_PERCENT_EQUITY      = 1, // Percentage of equity
   PROFIT_MODE_PRICE_DISTANCE_ONLY = 2  // Price-distance based only
};

enum ENUM_MAX_LEVEL_ACTION
{
   MAXLEVEL_STOP_AVERAGING = 0, // Stop averaging and wait for TP/recovery
   MAXLEVEL_CLOSE_BASKET   = 1, // Close basket
   MAXLEVEL_DISABLE_EA     = 2  // Disable EA
};

enum ENUM_MAX_LOSS_ACTION
{
   MAXLOSS_CLOSE_BASKET   = 0, // Close basket
   MAXLOSS_STOP_AVERAGING = 1, // Stop averaging
   MAXLOSS_DISABLE_EA     = 2  // Disable EA
};

enum ENUM_EMERGENCY_MODE
{
   EMERGENCY_CLOSE_BOTH               = 0, // Close both baskets immediately
   EMERGENCY_MANAGE_PROFITABLE_SIDE   = 1, // Close losing side, manage profitable side
   EMERGENCY_DISABLE_EA               = 2  // Disable EA, require manual intervention
};

//======================================================================
// STRUCTURES
//======================================================================
struct BasketPosition
{
   ulong    ticket;
   double   price;
   double   volume;
   double   profit;
   double   swap;
   double   commission;
   long     type;
   datetime openTime;
};

//======================================================================
// INPUT PARAMETERS
//======================================================================
input group "GENERAL"
input ulong    MagicNumber                    = 20260905;      // Magic number
input string   TradeComment                   = "FibBreakoutEA"; // Trade comment prefix
input bool     RequireHedgingAccount          = true;          // Require hedging account to trade
input string   AllowedSymbol                  = "";            // Restrict to symbol (blank = chart symbol)

input group "ENTRY"
input double   EntryDistance                  = 0.50;          // Breakout distance from market (price units)

input group "TAKE PROFIT"
input double   BasketTPDistance               = 0.50;          // Basket TP distance from weighted average
input double   MinimumBasketProfit            = 0.00;          // Minimum net profit required to close basket
input ENUM_PROFIT_MODE MinimumBasketProfitMode = PROFIT_MODE_CURRENCY; // Minimum profit mode
input bool     UseVirtualBasketTP             = true;          // Use EA-managed virtual basket TP
input bool     EnableProfitLock               = false;         // Lock in profit if it gives back too much from its peak
input double   ProfitLockActivation           = 1.00;          // Floating basket profit (currency) that arms the lock
input double   ProfitLockGivebackPercent      = 30.0;          // % giveback from peak profit that forces an immediate close

input group "AVERAGING"
input double   GridStep                       = 0.50;          // Distance between averaging levels (price units)
input double   InitialLot                     = 0.01;          // Initial (level 1) lot size
input int      MaximumMartingaleLevels        = 6;             // Maximum number of levels (includes initial)
input double   MaximumBasketLots              = 0.35;          // Maximum total basket lots allowed
input ENUM_MAX_LEVEL_ACTION MaximumLevelAction = MAXLEVEL_STOP_AVERAGING; // Action at maximum level

input group "ADAPTIVE GRID"
input bool     UseATRGrid                     = false;         // Size Entry/Grid/TP distances from ATR instead of fixed inputs
input ENUM_TIMEFRAMES ATRGridTimeframe        = PERIOD_H1;      // Timeframe the sizing ATR is measured on
input int      ATRGridPeriod                  = 14;             // ATR period for grid sizing
input double   ATRGridEntryMultiplier         = 1.0;            // EntryDistance = ATR * this multiplier
input double   ATRGridStepMultiplier          = 1.0;            // GridStep = ATR * this multiplier
input double   ATRGridTPMultiplier            = 1.0;            // BasketTPDistance = ATR * this multiplier
input double   ATRGridMinDistance             = 0.10;           // Floor applied to every ATR-derived distance

input group "RISK"
input bool     EnableMaximumBasketLoss        = true;          // Enable maximum basket loss protection
input double   MaximumBasketLoss              = 100.0;         // Maximum basket loss (account currency)
input ENUM_MAX_LOSS_ACTION MaximumBasketLossAction = MAXLOSS_CLOSE_BASKET; // Action at maximum basket loss
input bool     EnableEquityProtection         = true;          // Enable equity drawdown protection
input double   MaximumEquityDrawdownPercent   = 10.0;          // Maximum equity drawdown (%) from baseline
input bool     EnableDailyLossLimit           = true;          // Enable daily loss limit
input double   MaximumDailyLossPercent        = 5.0;           // Maximum daily loss (%) from day-start equity
input double   MinimumMarginLevelPercent      = 300.0;         // Minimum acceptable projected margin level (%)

input group "FILTERS"
input bool     EnableSpreadFilter             = true;          // Enable maximum spread filter
input double   MaximumSpread                  = 0.50;          // Maximum spread (price units)
input bool     EnableATRFilter                = false;         // Enable ATR volatility filter
input int      ATRPeriod                      = 14;            // ATR period
input double   MaximumATR                     = 5.00;          // Maximum ATR allowed for new cycles
input bool     EnableTrendFilter              = false;         // Enable optional EMA trend filter
input int      TrendEMAFastPeriod             = 20;            // Fast EMA period
input int      TrendEMASlowPeriod             = 50;            // Slow EMA period

input group "TRADING HOURS"
input bool     EnableTradingHours             = false;         // Restrict new entries to trading hours
input string   TradingStartTime               = "00:00";       // Trading start (server time, HH:MM)
input string   TradingEndTime                 = "23:59";       // Trading end (server time, HH:MM)
input bool     CloseBasketAtSessionEnd        = false;         // Force-close active basket at session end

input group "ORDERS"
input bool     EnablePendingExpiration        = true;          // Enable pending order expiration
input int      PendingExpirationMinutes       = 60;            // Expiration time for untriggered pendings (minutes)
input bool     AutoAdjustInvalidStopDistance  = true;          // Auto-adjust distances invalid for broker
input bool     AllowOneSidedCycle             = false;         // Allow cycle to continue if one pending order fails

input group "EXECUTION"
input int      MaximumSlippage                = 20;            // Maximum slippage / deviation (points)
input int      MaximumRetryAttempts           = 3;             // Maximum retry attempts for trade operations
input int      RetryDelayMilliseconds         = 500;           // Delay between retries (milliseconds)

input group "RECOVERY"
input ENUM_EMERGENCY_MODE BothSidesEmergencyMode = EMERGENCY_CLOSE_BOTH; // Both-sides emergency behaviour
input int      CooldownAfterTP                = 5;             // Cooldown after basket close (seconds)

//======================================================================
// GLOBAL STATE
//======================================================================
CTrade trade;

string  g_symbol             = "";
int     g_digits             = 2;
double  g_point              = 0.01;
double  g_tickSize           = 0.01;
double  g_tickValue          = 1.0;
double  g_volMin             = 0.01;
double  g_volMax             = 100.0;
double  g_volStep            = 0.01;
int     g_volDigits          = 2;
double  g_stopsLevelPoints   = 0;
double  g_freezeLevelPoints  = 0;
bool    g_isHedgingAccount   = false;

EAState g_state               = STATE_IDLE;
ENUM_BASKET_DIRECTION g_basketDirection = BASKET_NONE;
int     g_currentLevel        = 0;
double  g_lastEntryPrice      = 0;
double  g_nextAveragingPrice  = 0;
double  g_weightedAverage     = 0;
double  g_basketTP            = 0;
bool    g_maxLevelReached     = false;
bool    g_averagingBlocked    = false;
bool    g_averagingHardBlocked= false;
bool    g_marginProtectionTriggered = false;
bool    g_maxLevelActionExecuted    = false;
bool    g_profitLockArmed          = false;
double  g_basketPeakProfit         = 0;
bool    g_basketLossActionExecuted  = false;

string  g_cycleId      = "NONE";
string  g_cycleIdFull  = "NONE";
int     g_cycleCounter = 0;

datetime g_waitingSince   = 0;
datetime g_cooldownStart  = 0;

double  g_equityBaseline        = 0;
double  g_startOfDayEquity      = 0;
int     g_currentDayKey         = -1;
bool    g_dailyLossTriggered    = false;
bool    g_equityDrawdownTriggered = false;
bool    g_eaDisabled            = false;

bool    g_tradeLock = false;

int     g_atrHandle     = INVALID_HANDLE;
int     g_atrGridHandle = INVALID_HANDLE;
double  g_effEntryDistance    = 0;
double  g_effGridStep         = 0;
double  g_effBasketTPDistance = 0;
int     g_emaFastHandle = INVALID_HANDLE;
int     g_emaSlowHandle = INVALID_HANDLE;

MqlTick g_lastTick;

double  g_fibLots[64];
int     g_fibCount = 0;

string  g_dashLines[100];
int     g_dashLineCount = 0;
uint    g_lastDashboardUpdate = 0;

#define DASH_PREFIX      "FibEA_DASH_"
#define DASH_X           10
#define DASH_Y_START     20
#define DASH_LINE_HEIGHT 13
#define DASH_FONT_SIZE   8
#define DASH_FONT        "Consolas"

// Not an input by design: the broker's real session close time is read
// directly from the symbol's own trading-session schedule (SymbolInfoSessionTrade),
// which varies by broker/server and shouldn't be hand-configured. This is
// just how many minutes of safety margin to close ahead of that real close.
#define MARKET_CLOSE_SAFETY_MINUTES 10

//======================================================================
// FORWARD DECLARATIONS (grouped by category, implemented below)
//======================================================================
bool   InitializeSymbolInfo();
bool   ValidateEnvironment();
void   BuildFibonacciSequence();
void   LoadGlobalState();
void   SaveGlobalState();
string GVName(string key);
void   RebuildStateFromBroker();
void   UpdateDailyBaseline();
void   EvaluateGlobalRiskFlags();
void   ReconcileBasketState();
void   ActivateBasket(ENUM_BASKET_DIRECTION direction, bool cancelOpposite);
void   HandleEmergencyBothSides();
bool   StartNewCycle();
bool   CanStartNewCycle();
void   UpdateEffectiveGridDistances();
bool   ValidateStopDistances(double &buyPrice, double &sellPrice, double ask, double bid);
void   GetTrendPermissions(bool &allowBuy, bool &allowSell);
bool   PlaceInitialPendingOrders(double buyPrice, double sellPrice, bool placeBuy, bool placeSell);
bool   SendPendingOrder(bool isBuy, double price, string comment, ulong &ticket);
bool   SendMarketOrder(bool isBuy, double lot, string comment, ulong &posTicket, double &execPrice, double &execVolume);
bool   IsRetryableRetcode(uint rc);
ulong  FindBuyStop();
ulong  FindSellStop();
ulong  FindPendingOrderByType(ENUM_ORDER_TYPE type);
int    CountPendingOrders();
bool   CancelPendingOrder(ulong ticket);
void   CancelBuyStop();
void   CancelSellStop();
void   CancelAllPendingOrders();
datetime GetOldestPendingOrderTime();
void   CheckPendingExpiration();
int    FindBasketPositions(ENUM_BASKET_DIRECTION direction, BasketPosition &arr[]);
int    CountBasketPositions(ENUM_BASKET_DIRECTION direction);
int    CountAllEAPositions();
double CalculateWeightedAverage(ENUM_BASKET_DIRECTION direction);
double CalculateBasketProfit(ENUM_BASKET_DIRECTION direction);
double CalculateBasketLots(ENUM_BASKET_DIRECTION direction);
double GetLastEntryPrice(ENUM_BASKET_DIRECTION direction);
void   RecalculateBasketMetrics(ENUM_BASKET_DIRECTION direction);
void   CheckForBasketTP();
void   CheckProfitLock();
void   SyncBrokerSideTakeProfit(ENUM_BASKET_DIRECTION direction);
double GetMinimumProfitThreshold();
void   BeginBasketClose();
void   ProcessBasketClosing();
void   EnterCooldown();
void   CheckMaximumBasketLoss();
void   CheckForAveraging();
bool   PassRiskChecksForAveraging(double lot);
void   OpenAveragingPosition(ENUM_BASKET_DIRECTION direction, double lot, int level);
void   HandleMaxLevelReached();
double GetFibonacciLot(int level);
double NormalizeVolume(double volume);
double NormalizePriceToTick(double price);
string PxStr(double price);
bool   IsSpreadAcceptable();
bool   IsWithinTradingHours();
bool   IsNearMarketClose();
int    ParseTimeToMinutes(string t);
bool   IsVolatilityAcceptable();
bool   IsMarginSafe(double volume, ENUM_ORDER_TYPE orderType);
bool   IsTradingAllowed();
void   CloseAllEAPositions();
void   CloseBasketDirection(ENUM_BASKET_DIRECTION direction);
void   DisableEA(string reason);
void   GenerateNewCycleId();
string BuildTradeComment(string tag);
string GetAccountMarginModeString();
string StateToString(EAState s);
string DirectionToString(ENUM_BASKET_DIRECTION d);
void   WriteTradeLog(string category, string message);
void   LogError(string message);
void   AddDashLine(string text);
void   RenderDashboard();
void   RemoveDashboard();
void   UpdateDashboard();

//======================================================================
// EVENT HANDLERS
//======================================================================
int OnInit()
{
   if(!InitializeSymbolInfo())
   {
      WriteTradeLog("ERROR","Symbol initialization failed. EA cannot start.");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints((ulong)MaximumSlippage);

   BuildFibonacciSequence();

   g_equityBaseline = AccountInfoDouble(ACCOUNT_EQUITY);
   g_currentDayKey  = -1;
   UpdateDailyBaseline();

   LoadGlobalState();

   if(EnableATRFilter)
      g_atrHandle = iATR(g_symbol, PERIOD_CURRENT, ATRPeriod);

   if(EnableTrendFilter)
   {
      g_emaFastHandle = iMA(g_symbol, PERIOD_CURRENT, TrendEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
      g_emaSlowHandle = iMA(g_symbol, PERIOD_CURRENT, TrendEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   }

   if(UseATRGrid)
      g_atrGridHandle = iATR(g_symbol, ATRGridTimeframe, ATRGridPeriod);

   // Seed effective grid distances before any restart-recovered basket
   // calls RecalculateBasketMetrics() below, so it never computes against
   // an uninitialized (zero) distance.
   UpdateEffectiveGridDistances();

   bool envOk = ValidateEnvironment();

   if(!envOk)
   {
      g_state = STATE_ERROR;
      WriteTradeLog("INIT","EA initialized with errors. Trading is DISABLED. See ERROR log above.");
   }
   else if(g_eaDisabled)
   {
      g_state = STATE_ERROR;
      WriteTradeLog("INIT","EA was previously disabled by a risk event. Trading remains DISABLED until manually reset.");
   }
   else
   {
      RebuildStateFromBroker();
      WriteTradeLog("INIT","EA initialized successfully.");
   }

   EventSetTimer(1);
   UpdateDashboard();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   RemoveDashboard();
   if(g_atrHandle != INVALID_HANDLE)     IndicatorRelease(g_atrHandle);
   if(g_atrGridHandle != INVALID_HANDLE) IndicatorRelease(g_atrGridHandle);
   if(g_emaFastHandle != INVALID_HANDLE) IndicatorRelease(g_emaFastHandle);
   if(g_emaSlowHandle != INVALID_HANDLE) IndicatorRelease(g_emaSlowHandle);
}

void OnTick()
{
   if(!SymbolInfoTick(g_symbol, g_lastTick))
      return;

   UpdateDailyBaseline();
   EvaluateGlobalRiskFlags();

   if(g_tradeLock)
      return;
   g_tradeLock = true;

   if(g_state != STATE_ERROR)
      ReconcileBasketState();

   switch(g_state)
   {
      case STATE_EMERGENCY_BOTH_SIDES:
         HandleEmergencyBothSides();
         break;

      case STATE_IDLE:
         StartNewCycle();
         break;

      case STATE_WAITING_FOR_BREAKOUT:
         CheckPendingExpiration();
         if(g_state == STATE_WAITING_FOR_BREAKOUT && IsNearMarketClose())
         {
            WriteTradeLog("CYCLE", "Market close approaching. Cancelling pending breakout orders.");
            CancelAllPendingOrders();
            g_state = STATE_COOLDOWN;
            g_cooldownStart = TimeCurrent();
         }
         break;

      case STATE_BUY_ACTIVE:
      case STATE_SELL_ACTIVE:
         RecalculateBasketMetrics(g_basketDirection);
         SyncBrokerSideTakeProfit(g_basketDirection);

         if(IsNearMarketClose())
         {
            WriteTradeLog("CLOSE", "Market close approaching. Closing open basket.");
            BeginBasketClose();
         }

         if(EnableTradingHours && CloseBasketAtSessionEnd && !IsWithinTradingHours())
            BeginBasketClose();

         if(g_state == STATE_BUY_ACTIVE || g_state == STATE_SELL_ACTIVE)
            CheckMaximumBasketLoss();

         if(g_state == STATE_BUY_ACTIVE || g_state == STATE_SELL_ACTIVE)
            CheckProfitLock();

         if(g_state == STATE_BUY_ACTIVE || g_state == STATE_SELL_ACTIVE)
            CheckForBasketTP();

         if(g_state == STATE_BUY_ACTIVE || g_state == STATE_SELL_ACTIVE)
            CheckForAveraging();
         break;

      case STATE_TP_CLOSING:
         ProcessBasketClosing();
         break;

      case STATE_COOLDOWN:
         if((int)(TimeCurrent() - g_cooldownStart) >= CooldownAfterTP)
            g_state = STATE_IDLE;
         break;

      case STATE_RISK_STOP:
      case STATE_ERROR:
      default:
         break;
   }

   g_tradeLock = false;

   if(GetTickCount() - g_lastDashboardUpdate > 200)
   {
      g_lastDashboardUpdate = GetTickCount();
      UpdateDashboard();
   }
}

void OnTimer()
{
   if(g_state == STATE_COOLDOWN)
   {
      if((int)(TimeCurrent() - g_cooldownStart) >= CooldownAfterTP)
         g_state = STATE_IDLE;
   }
   else if(g_state == STATE_WAITING_FOR_BREAKOUT)
   {
      CheckPendingExpiration();
   }
   UpdateDashboard();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   // Reconciliation is broker-state driven (see ReconcileBasketState), so we
   // simply nudge the next OnTick to re-scan promptly. This keeps a single,
   // consistent source of truth instead of maintaining a parallel event path.
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD ||
      trans.type == TRADE_TRANSACTION_ORDER_DELETE ||
      trans.type == TRADE_TRANSACTION_HISTORY_ADD)
   {
      if(!g_tradeLock)
         ReconcileBasketState();
   }
}

//======================================================================
// INITIALIZATION HELPERS
//======================================================================
bool InitializeSymbolInfo()
{
   string chartSymbol = _Symbol;

   if(StringLen(AllowedSymbol) == 0)
   {
      g_symbol = chartSymbol;
   }
   else
   {
      if(AllowedSymbol == chartSymbol || StringFind(chartSymbol, AllowedSymbol) == 0)
         g_symbol = chartSymbol;
      else
      {
         WriteTradeLog("ERROR", StringFormat("Chart symbol %s does not match AllowedSymbol %s.", chartSymbol, AllowedSymbol));
         return false;
      }
   }

   if(!SymbolSelect(g_symbol, true))
   {
      WriteTradeLog("ERROR", "Failed to select symbol " + g_symbol);
      return false;
   }

   g_digits            = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   g_point             = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   g_tickSize          = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_tickSize <= 0) g_tickSize = g_point;
   g_tickValue         = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   g_volMin            = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   g_volMax            = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   g_volStep           = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   g_volDigits         = 0;
   {
      double step = g_volStep;
      while(step < 0.9999 && g_volDigits < 8)
      {
         step *= 10.0;
         g_volDigits++;
      }
   }
   g_stopsLevelPoints  = (double)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_freezeLevelPoints = (double)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   return true;
}

bool ValidateEnvironment()
{
   bool ok = true;

   ENUM_ACCOUNT_MARGIN_MODE mode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   g_isHedgingAccount = (mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

   if(!g_isHedgingAccount)
   {
      WriteTradeLog("INIT", "WARNING: Account margin mode is " + GetAccountMarginModeString() +
                    ". This EA requires multiple simultaneous same-direction positions and is designed for hedging accounts.");
      if(RequireHedgingAccount)
      {
         WriteTradeLog("ERROR", "RequireHedgingAccount=true and the account is not a hedging account. Trading disabled.");
         ok = false;
      }
   }

   if(SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      WriteTradeLog("ERROR", "Trading is disabled for symbol " + g_symbol);
      ok = false;
   }

   if(MaximumMartingaleLevels < 1)
   {
      WriteTradeLog("ERROR", "MaximumMartingaleLevels must be >= 1.");
      ok = false;
   }

   if(InitialLot <= 0)
   {
      WriteTradeLog("ERROR", "InitialLot must be > 0.");
      ok = false;
   }

   if(EntryDistance <= 0 || GridStep <= 0 || BasketTPDistance <= 0)
   {
      WriteTradeLog("ERROR", "EntryDistance, GridStep and BasketTPDistance must all be > 0.");
      ok = false;
   }

   return ok;
}

void BuildFibonacciSequence()
{
   ArrayInitialize(g_fibLots, 0.0);
   int maxLevels = MaximumMartingaleLevels;
   if(maxLevels < 1)  maxLevels = 1;
   if(maxLevels > 64) maxLevels = 64;

   g_fibLots[0] = NormalizeVolume(InitialLot);
   if(maxLevels > 1)
      g_fibLots[1] = NormalizeVolume(InitialLot * 2.0);

   for(int i = 2; i < maxLevels; i++)
      g_fibLots[i] = NormalizeVolume(g_fibLots[i-1] + g_fibLots[i-2]);

   g_fibCount = maxLevels;
}

string GVName(string key)
{
   return StringFormat("FibEA_%s_%I64u_%s", g_symbol, MagicNumber, key);
}

void SaveGlobalState()
{
   GlobalVariableSet(GVName("Disabled"), g_eaDisabled ? 1.0 : 0.0);
   GlobalVariableSet(GVName("EquityDD"), g_equityDrawdownTriggered ? 1.0 : 0.0);
   GlobalVariableSet(GVName("CycleCounter"), (double)g_cycleCounter);
}

void LoadGlobalState()
{
   string k1 = GVName("Disabled");
   string k2 = GVName("EquityDD");
   string k3 = GVName("CycleCounter");
   if(GlobalVariableCheck(k1)) g_eaDisabled              = GlobalVariableGet(k1) > 0.5;
   if(GlobalVariableCheck(k2)) g_equityDrawdownTriggered = GlobalVariableGet(k2) > 0.5;
   if(GlobalVariableCheck(k3)) g_cycleCounter             = (int)GlobalVariableGet(k3);
}

//======================================================================
// RESTART RECOVERY / STATE RECONCILIATION
//======================================================================
void RebuildStateFromBroker()
{
   int buyCount  = CountBasketPositions(BASKET_BUY);
   int sellCount = CountBasketPositions(BASKET_SELL);

   if(buyCount > 0 && sellCount > 0)
   {
      g_state = STATE_EMERGENCY_BOTH_SIDES;
      WriteTradeLog("ERROR", "Both-sided basket detected on restart. Entering emergency handling.");
      return;
   }

   if(buyCount > 0)
   {
      WriteTradeLog("INIT", "Recovering BUY basket from broker state (" + IntegerToString(buyCount) + " positions).");
      ActivateBasket(BASKET_BUY, true);
      return;
   }

   if(sellCount > 0)
   {
      WriteTradeLog("INIT", "Recovering SELL basket from broker state (" + IntegerToString(sellCount) + " positions).");
      ActivateBasket(BASKET_SELL, true);
      return;
   }

   ulong bt = FindBuyStop();
   ulong st = FindSellStop();
   if(bt != 0 || st != 0)
   {
      g_state = STATE_WAITING_FOR_BREAKOUT;
      g_waitingSince = GetOldestPendingOrderTime();
      WriteTradeLog("INIT", "Recovered pending breakout order(s). Waiting for trigger.");
      return;
   }

   g_state = STATE_IDLE;
   WriteTradeLog("INIT", "No existing basket or pending orders found. Ready for a new cycle.");
}

void UpdateDailyBaseline()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int today = dt.year * 10000 + dt.mon * 100 + dt.day;

   if(today != g_currentDayKey)
   {
      g_currentDayKey    = today;
      g_startOfDayEquity = AccountInfoDouble(ACCOUNT_EQUITY);

      if(g_dailyLossTriggered)
      {
         g_dailyLossTriggered = false;
         WriteTradeLog("RISK", "New trading day started. Daily loss limit flag reset.");
         if(g_state == STATE_RISK_STOP && !g_equityDrawdownTriggered && !g_eaDisabled)
            g_state = STATE_IDLE;
      }
   }
}

void EvaluateGlobalRiskFlags()
{
   if(g_eaDisabled)
      return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(EnableEquityProtection && !g_equityDrawdownTriggered && g_equityBaseline > 0)
   {
      double dd = (g_equityBaseline - equity) / g_equityBaseline * 100.0;
      if(dd >= MaximumEquityDrawdownPercent)
      {
         g_equityDrawdownTriggered = true;
         WriteTradeLog("RISK", StringFormat("Maximum equity drawdown reached: %.2f%%. Closing EA positions and disabling new trading.", dd));
         CancelAllPendingOrders();
         CloseAllEAPositions();
         g_eaDisabled = true;
         SaveGlobalState();
         if(g_state != STATE_TP_CLOSING)
            g_state = STATE_RISK_STOP;
      }
   }

   if(EnableDailyLossLimit && !g_dailyLossTriggered && g_startOfDayEquity > 0)
   {
      double dl = (g_startOfDayEquity - equity) / g_startOfDayEquity * 100.0;
      if(dl >= MaximumDailyLossPercent)
      {
         g_dailyLossTriggered = true;
         WriteTradeLog("RISK", StringFormat("Maximum daily loss reached: %.2f%%. Blocking new cycles and averaging until next trading day.", dl));
         if(g_state == STATE_IDLE || g_state == STATE_WAITING_FOR_BREAKOUT)
         {
            CancelAllPendingOrders();
            g_state = STATE_RISK_STOP;
         }
      }
   }
}

void ReconcileBasketState()
{
   int buyCount  = CountBasketPositions(BASKET_BUY);
   int sellCount = CountBasketPositions(BASKET_SELL);

   if(buyCount > 0 && sellCount > 0)
   {
      if(g_state != STATE_EMERGENCY_BOTH_SIDES)
      {
         WriteTradeLog("ERROR", "Both BUY and SELL breakout orders triggered.");
         g_state = STATE_EMERGENCY_BOTH_SIDES;
      }
      return;
   }

   if(buyCount > 0)
   {
      if(g_state == STATE_WAITING_FOR_BREAKOUT || g_state == STATE_IDLE || g_state == STATE_RISK_STOP)
      {
         WriteTradeLog("TRIGGER", "BUY STOP triggered.");
         ActivateBasket(BASKET_BUY, true);
      }
      else if(g_state == STATE_BUY_ACTIVE)
      {
         if(FindSellStop() != 0)
         {
            WriteTradeLog("CANCEL", "Residual SELL STOP detected while BUY basket is active. Cancelling.");
            CancelSellStop();
         }
      }
      return;
   }

   if(sellCount > 0)
   {
      if(g_state == STATE_WAITING_FOR_BREAKOUT || g_state == STATE_IDLE || g_state == STATE_RISK_STOP)
      {
         WriteTradeLog("TRIGGER", "SELL STOP triggered.");
         ActivateBasket(BASKET_SELL, true);
      }
      else if(g_state == STATE_SELL_ACTIVE)
      {
         if(FindBuyStop() != 0)
         {
            WriteTradeLog("CANCEL", "Residual BUY STOP detected while SELL basket is active. Cancelling.");
            CancelBuyStop();
         }
      }
      return;
   }

   // No positions on either side.
   if(g_state == STATE_BUY_ACTIVE || g_state == STATE_SELL_ACTIVE)
   {
      WriteTradeLog("CLOSE", "Basket positions no longer present (closed externally or by broker). Entering cooldown.");
      EnterCooldown();
   }
   else if(g_state == STATE_WAITING_FOR_BREAKOUT && CountPendingOrders() == 0)
   {
      WriteTradeLog("CYCLE", "Pending breakout orders no longer present without a trigger. Returning to idle.");
      g_state = STATE_IDLE;
   }
}

void ActivateBasket(ENUM_BASKET_DIRECTION direction, bool cancelOpposite)
{
   g_basketDirection = direction;
   RecalculateBasketMetrics(direction);
   SyncBrokerSideTakeProfit(direction);
   g_profitLockArmed = false;
   g_basketPeakProfit = 0;
   g_state = (direction == BASKET_BUY) ? STATE_BUY_ACTIVE : STATE_SELL_ACTIVE;

   if(cancelOpposite)
   {
      if(direction == BASKET_BUY) CancelSellStop();
      else                        CancelBuyStop();
   }

   WriteTradeLog("BASKET", StringFormat("%s basket active. Level=%d Average=%s TP=%s",
                 DirectionToString(direction), g_currentLevel, PxStr(g_weightedAverage), PxStr(g_basketTP)));
}

void HandleEmergencyBothSides()
{
   CancelAllPendingOrders();

   switch(BothSidesEmergencyMode)
   {
      case EMERGENCY_CLOSE_BOTH:
      {
         CloseAllEAPositions();
         if(CountBasketPositions(BASKET_BUY) == 0 && CountBasketPositions(BASKET_SELL) == 0)
            EnterCooldown();
         break;
      }
      case EMERGENCY_MANAGE_PROFITABLE_SIDE:
      {
         double buyProfit  = CalculateBasketProfit(BASKET_BUY);
         double sellProfit = CalculateBasketProfit(BASKET_SELL);
         ENUM_BASKET_DIRECTION losing  = (buyProfit < sellProfit) ? BASKET_BUY : BASKET_SELL;
         ENUM_BASKET_DIRECTION winning = (losing == BASKET_BUY) ? BASKET_SELL : BASKET_BUY;

         CloseBasketDirection(losing);

         if(CountBasketPositions(losing) == 0 && CountBasketPositions(winning) > 0)
         {
            WriteTradeLog("BASKET", "Emergency: losing side closed. Resuming normal management of " + DirectionToString(winning) + " side.");
            ActivateBasket(winning, false);
         }
         else if(CountBasketPositions(winning) == 0)
         {
            EnterCooldown();
         }
         break;
      }
      case EMERGENCY_DISABLE_EA:
      {
         DisableEA("Emergency both-sides trigger - manual intervention required.");
         break;
      }
   }
}

//======================================================================
// NEW CYCLE / PENDING ORDER PLACEMENT
//======================================================================
bool CanStartNewCycle()
{
   if(g_eaDisabled)                                   return false;
   if(g_dailyLossTriggered || g_equityDrawdownTriggered) return false;
   if(CountAllEAPositions() > 0)                      return false;
   if(CountPendingOrders() > 0)                       return false;
   if(!IsTradingAllowed())                            return false;
   if(EnableSpreadFilter && !IsSpreadAcceptable())     return false;
   if(EnableTradingHours && !IsWithinTradingHours())   return false;
   if(IsNearMarketClose())                             return false;
   if(EnableATRFilter && !IsVolatilityAcceptable())    return false;
   if(!IsMarginSafe(NormalizeVolume(InitialLot), ORDER_TYPE_BUY)) return false;
   return true;
}

// Snapshots EntryDistance/GridStep/BasketTPDistance for the cycle about to
// start. With UseATRGrid=false these are simply the fixed inputs (default,
// unchanged behavior). With UseATRGrid=true they are recomputed from the
// current ATR reading instead — sized to whatever the instrument is
// actually doing rather than a static guess. Snapshotting once per cycle
// (not recalculating mid-basket) keeps a basket's own grid spacing
// internally consistent for its whole lifetime; only a brand-new cycle
// picks up a new ATR reading. Also called once at OnInit() so a basket
// recovered on restart (see RebuildStateFromBroker) has valid distances
// before RecalculateBasketMetrics() first runs.
void UpdateEffectiveGridDistances()
{
   if(!UseATRGrid)
   {
      g_effEntryDistance    = EntryDistance;
      g_effGridStep         = GridStep;
      g_effBasketTPDistance = BasketTPDistance;
      return;
   }

   double atr = 0;
   if(g_atrGridHandle != INVALID_HANDLE)
   {
      double buf[1];
      if(CopyBuffer(g_atrGridHandle, 0, 0, 1, buf) > 0)
         atr = buf[0];
   }

   if(atr <= 0)
   {
      g_effEntryDistance    = EntryDistance;
      g_effGridStep         = GridStep;
      g_effBasketTPDistance = BasketTPDistance;
      WriteTradeLog("CYCLE", "ATR grid sizing unavailable (ATR<=0, likely insufficient history) - using fixed distance inputs instead.");
      return;
   }

   g_effEntryDistance    = MathMax(atr * ATRGridEntryMultiplier, ATRGridMinDistance);
   g_effGridStep         = MathMax(atr * ATRGridStepMultiplier,  ATRGridMinDistance);
   g_effBasketTPDistance = MathMax(atr * ATRGridTPMultiplier,    ATRGridMinDistance);

   WriteTradeLog("CYCLE", StringFormat("ATR grid sizing: ATR=%s Entry=%s Grid=%s TP=%s",
                 PxStr(atr), PxStr(g_effEntryDistance), PxStr(g_effGridStep), PxStr(g_effBasketTPDistance)));
}

bool StartNewCycle()
{
   if(!CanStartNewCycle())
      return false;

   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0)
      return false;

   UpdateEffectiveGridDistances();

   double buyStopPrice  = NormalizePriceToTick(ask + g_effEntryDistance);
   double sellStopPrice = NormalizePriceToTick(bid - g_effEntryDistance);

   if(!ValidateStopDistances(buyStopPrice, sellStopPrice, ask, bid))
      return false;

   bool allowBuy = true, allowSell = true;
   GetTrendPermissions(allowBuy, allowSell);
   if(!allowBuy && !allowSell) { allowBuy = true; allowSell = true; }

   GenerateNewCycleId();

   bool ok = PlaceInitialPendingOrders(buyStopPrice, sellStopPrice, allowBuy, allowSell);
   if(ok)
   {
      g_state = STATE_WAITING_FOR_BREAKOUT;
      g_waitingSince = TimeCurrent();
      WriteTradeLog("CYCLE", "New cycle started: " + g_cycleIdFull);
   }
   return ok;
}

bool ValidateStopDistances(double &buyPrice, double &sellPrice, double ask, double bid)
{
   double minDistPoints = MathMax(g_stopsLevelPoints, g_freezeLevelPoints);
   double minDist = minDistPoints * g_point;
   double buffer  = g_tickSize;
   bool adjusted = false;

   if(minDist > 0)
   {
      if((buyPrice - ask) < minDist)
      {
         if(!AutoAdjustInvalidStopDistance)
         {
            WriteTradeLog("ERROR", "EntryDistance too small for BUY STOP given broker stop level. Required >= " + PxStr(minDist));
            return false;
         }
         buyPrice = NormalizePriceToTick(ask + minDist + buffer);
         adjusted = true;
      }
      if((bid - sellPrice) < minDist)
      {
         if(!AutoAdjustInvalidStopDistance)
         {
            WriteTradeLog("ERROR", "EntryDistance too small for SELL STOP given broker stop level. Required >= " + PxStr(minDist));
            return false;
         }
         sellPrice = NormalizePriceToTick(bid - minDist - buffer);
         adjusted = true;
      }
   }

   if(adjusted)
      WriteTradeLog("CYCLE", "Entry distance auto-adjusted to satisfy broker minimum stop/freeze level.");

   return true;
}

void GetTrendPermissions(bool &allowBuy, bool &allowSell)
{
   allowBuy  = true;
   allowSell = true;
   if(!EnableTrendFilter) return;
   if(g_emaFastHandle == INVALID_HANDLE || g_emaSlowHandle == INVALID_HANDLE) return;

   double fastBuf[1], slowBuf[1];
   if(CopyBuffer(g_emaFastHandle, 0, 0, 1, fastBuf) <= 0) return;
   if(CopyBuffer(g_emaSlowHandle, 0, 0, 1, slowBuf) <= 0) return;

   if(fastBuf[0] > slowBuf[0])      { allowBuy = true;  allowSell = false; }
   else if(fastBuf[0] < slowBuf[0]) { allowBuy = false; allowSell = true;  }
}

bool PlaceInitialPendingOrders(double buyPrice, double sellPrice, bool placeBuy, bool placeSell)
{
   ulong buyTicket = 0, sellTicket = 0;

   if(placeBuy)
   {
      string buyComment = BuildTradeComment("BS");
      if(!SendPendingOrder(true, buyPrice, buyComment, buyTicket))
      {
         WriteTradeLog("ERROR", "Failed to place BUY STOP. Cycle aborted.");
         return false;
      }
      WriteTradeLog("ENTRY", StringFormat("BUY STOP placed at %s ticket=%I64u", PxStr(buyPrice), buyTicket));
   }
   else
   {
      WriteTradeLog("FILTER", "Trend filter restricts this cycle: BUY STOP not placed.");
   }

   if(placeSell)
   {
      string sellComment = BuildTradeComment("SS");
      if(!SendPendingOrder(false, sellPrice, sellComment, sellTicket))
      {
         WriteTradeLog("ERROR", "Failed to place SELL STOP.");
         if(placeBuy && !AllowOneSidedCycle)
         {
            WriteTradeLog("CANCEL", "Cancelling BUY STOP due to failed SELL STOP (AllowOneSidedCycle=false).");
            CancelPendingOrder(buyTicket);
            return false;
         }
         if(!placeBuy)
            return false; // neither side placed
         WriteTradeLog("ENTRY", "Continuing with one-sided cycle (BUY STOP only) per AllowOneSidedCycle=true.");
         return true;
      }
      WriteTradeLog("ENTRY", StringFormat("SELL STOP placed at %s ticket=%I64u", PxStr(sellPrice), sellTicket));
   }
   else
   {
      WriteTradeLog("FILTER", "Trend filter restricts this cycle: SELL STOP not placed.");
   }

   if(!placeBuy && !placeSell)
      return false;

   return true;
}

bool SendPendingOrder(bool isBuy, double price, string comment, ulong &ticket)
{
   double lot = NormalizeVolume(InitialLot);

   for(int attempt = 0; attempt < MaximumRetryAttempts; attempt++)
   {
      bool sent = isBuy ?
                  trade.BuyStop(lot, price, g_symbol, 0, 0, ORDER_TIME_GTC, 0, comment) :
                  trade.SellStop(lot, price, g_symbol, 0, 0, ORDER_TIME_GTC, 0, comment);
      uint rc = trade.ResultRetcode();

      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
      {
         ticket = trade.ResultOrder();
         if(ticket != 0 && OrderSelect(ticket))
            return true;
         LogError(StringFormat("Order reported placed but could not be verified via OrderSelect. Ticket=%I64u", ticket));
         return false;
      }

      if(IsRetryableRetcode(rc))
      {
         LogError(StringFormat("Retryable error placing pending order: %u. Attempt %d/%d.", rc, attempt + 1, MaximumRetryAttempts));
         Sleep(RetryDelayMilliseconds);
         continue;
      }

      LogError(StringFormat("Pending order placement failed with non-retryable retcode: %u.", rc));
      return false;
   }
   return false;
}

bool SendMarketOrder(bool isBuy, double lot, string comment, ulong &posTicket, double &execPrice, double &execVolume)
{
   double normLot = NormalizeVolume(lot);

   for(int attempt = 0; attempt < MaximumRetryAttempts; attempt++)
   {
      bool sent = isBuy ?
                  trade.Buy(normLot, g_symbol, 0, 0, 0, comment) :
                  trade.Sell(normLot, g_symbol, 0, 0, 0, comment);
      uint rc = trade.ResultRetcode();

      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL))
      {
         ulong dealTicket = trade.ResultDeal();
         if(dealTicket != 0 && HistoryDealSelect(dealTicket))
         {
            execPrice  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
            execVolume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
            posTicket  = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
         }
         else
         {
            execPrice  = trade.ResultPrice();
            execVolume = trade.ResultVolume();
            posTicket  = trade.ResultOrder();
         }
         return true;
      }

      if(IsRetryableRetcode(rc))
      {
         LogError(StringFormat("Retryable error on market order: %u. Attempt %d/%d.", rc, attempt + 1, MaximumRetryAttempts));
         Sleep(RetryDelayMilliseconds);
         continue;
      }

      LogError(StringFormat("Market order failed, retcode=%u.", rc));
      return false;
   }
   return false;
}

bool IsRetryableRetcode(uint rc)
{
   return (rc == TRADE_RETCODE_REQUOTE ||
           rc == TRADE_RETCODE_PRICE_CHANGED ||
           rc == TRADE_RETCODE_PRICE_OFF ||
           rc == TRADE_RETCODE_TOO_MANY_REQUESTS);
}

//======================================================================
// PENDING ORDER MANAGEMENT
//======================================================================
ulong FindBuyStop()  { return FindPendingOrderByType(ORDER_TYPE_BUY_STOP); }
ulong FindSellStop() { return FindPendingOrderByType(ORDER_TYPE_SELL_STOP); }

ulong FindPendingOrderByType(ENUM_ORDER_TYPE type)
{
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != (long)MagicNumber) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != type) continue;
      return ticket;
   }
   return 0;
}

int CountPendingOrders()
{
   int count = 0;
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != (long)MagicNumber) continue;
      count++;
   }
   return count;
}

bool CancelPendingOrder(ulong ticket)
{
   if(ticket == 0) return true;
   if(!OrderSelect(ticket)) return true;

   for(int attempt = 0; attempt < MaximumRetryAttempts; attempt++)
   {
      trade.OrderDelete(ticket);
      if(!OrderSelect(ticket))
      {
         WriteTradeLog("CANCEL", StringFormat("Pending order %I64u cancelled.", ticket));
         return true;
      }
      Sleep(RetryDelayMilliseconds);
   }

   LogError(StringFormat("Failed to cancel pending order %I64u after %d attempts.", ticket, MaximumRetryAttempts));
   return false;
}

void CancelBuyStop()
{
   ulong t = FindBuyStop();
   if(t != 0) CancelPendingOrder(t);
}

void CancelSellStop()
{
   ulong t = FindSellStop();
   if(t != 0) CancelPendingOrder(t);
}

void CancelAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != (long)MagicNumber) continue;
      CancelPendingOrder(ticket);
   }
}

datetime GetOldestPendingOrderTime()
{
   datetime oldest = 0;
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != (long)MagicNumber) continue;
      datetime t = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(oldest == 0 || t < oldest) oldest = t;
   }
   return (oldest == 0) ? TimeCurrent() : oldest;
}

void CheckPendingExpiration()
{
   if(!EnablePendingExpiration) return;
   if(g_waitingSince == 0) return;

   int elapsedMin = (int)((TimeCurrent() - g_waitingSince) / 60);
   if(elapsedMin >= PendingExpirationMinutes)
   {
      WriteTradeLog("CYCLE", StringFormat("Pending orders expired after %d minutes without trigger. Cancelling.", PendingExpirationMinutes));
      CancelAllPendingOrders();
      g_state = STATE_COOLDOWN;
      g_cooldownStart = TimeCurrent();
   }
}

//======================================================================
// BASKET / POSITION QUERIES
//======================================================================
int FindBasketPositions(ENUM_BASKET_DIRECTION direction, BasketPosition &arr[])
{
   ArrayResize(arr, 0);
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(direction == BASKET_BUY  && type != POSITION_TYPE_BUY)  continue;
      if(direction == BASKET_SELL && type != POSITION_TYPE_SELL) continue;

      int n = ArraySize(arr);
      ArrayResize(arr, n + 1);
      arr[n].ticket     = ticket;
      arr[n].price      = PositionGetDouble(POSITION_PRICE_OPEN);
      arr[n].volume     = PositionGetDouble(POSITION_VOLUME);
      arr[n].profit     = PositionGetDouble(POSITION_PROFIT);
      arr[n].swap       = PositionGetDouble(POSITION_SWAP);
      arr[n].commission = PositionGetDouble(POSITION_COMMISSION);
      arr[n].type       = (long)type;
      arr[n].openTime   = (datetime)PositionGetInteger(POSITION_TIME);
   }
   return ArraySize(arr);
}

int CountBasketPositions(ENUM_BASKET_DIRECTION direction)
{
   BasketPosition arr[];
   return FindBasketPositions(direction, arr);
}

int CountAllEAPositions()
{
   return CountBasketPositions(BASKET_BUY) + CountBasketPositions(BASKET_SELL);
}

double CalculateWeightedAverage(ENUM_BASKET_DIRECTION direction)
{
   BasketPosition arr[];
   int count = FindBasketPositions(direction, arr);
   if(count == 0) return 0;

   double sumPV = 0, sumV = 0;
   for(int i = 0; i < count; i++)
   {
      sumPV += arr[i].price * arr[i].volume;
      sumV  += arr[i].volume;
   }
   if(sumV <= 0) return 0;
   return NormalizeDouble(sumPV / sumV, g_digits);
}

double CalculateBasketProfit(ENUM_BASKET_DIRECTION direction)
{
   BasketPosition arr[];
   int count = FindBasketPositions(direction, arr);
   double total = 0;
   for(int i = 0; i < count; i++)
      total += arr[i].profit + arr[i].swap + arr[i].commission;
   return total;
}

double CalculateBasketLots(ENUM_BASKET_DIRECTION direction)
{
   BasketPosition arr[];
   int count = FindBasketPositions(direction, arr);
   double total = 0;
   for(int i = 0; i < count; i++)
      total += arr[i].volume;
   return total;
}

double GetLastEntryPrice(ENUM_BASKET_DIRECTION direction)
{
   BasketPosition arr[];
   int count = FindBasketPositions(direction, arr);
   if(count == 0) return 0;

   int latestIdx = 0;
   datetime latestTime = arr[0].openTime;
   for(int i = 1; i < count; i++)
   {
      if(arr[i].openTime > latestTime)
      {
         latestTime = arr[i].openTime;
         latestIdx = i;
      }
   }
   return arr[latestIdx].price;
}

void RecalculateBasketMetrics(ENUM_BASKET_DIRECTION direction)
{
   int count = CountBasketPositions(direction);
   g_currentLevel = count;
   g_weightedAverage = CalculateWeightedAverage(direction);

   g_basketTP = (direction == BASKET_BUY) ?
                NormalizePriceToTick(g_weightedAverage + g_effBasketTPDistance) :
                NormalizePriceToTick(g_weightedAverage - g_effBasketTPDistance);

   g_lastEntryPrice = GetLastEntryPrice(direction);
   g_nextAveragingPrice = (direction == BASKET_BUY) ?
                           NormalizePriceToTick(g_lastEntryPrice - g_effGridStep) :
                           NormalizePriceToTick(g_lastEntryPrice + g_effGridStep);

   g_maxLevelReached = (g_currentLevel >= MaximumMartingaleLevels);
}

//======================================================================
// BASKET TAKE PROFIT / CLOSING
//======================================================================
double GetMinimumProfitThreshold()
{
   switch(MinimumBasketProfitMode)
   {
      case PROFIT_MODE_CURRENCY:            return MinimumBasketProfit;
      case PROFIT_MODE_PERCENT_EQUITY:      return AccountInfoDouble(ACCOUNT_EQUITY) * MinimumBasketProfit / 100.0;
      case PROFIT_MODE_PRICE_DISTANCE_ONLY: return -1.0e9; // price reaching TP alone is sufficient
   }
   return MinimumBasketProfit;
}

// Protects against a favorable spike that overshoots BasketTPDistance and
// then gives most of it back before the ordinary TP check (or a broker-side
// TP order) ever fires — most commonly seen against coarse/synthetic tester
// tick data, but equally applicable to a real fast-market spike live. Tracks
// the basket's peak floating profit; once that peak clears
// ProfitLockActivation, a pullback of ProfitLockGivebackPercent% from the
// peak forces an immediate close. Independent of UseVirtualBasketTP so it
// backstops broker-side TP mode too. Never closes at a loss.
void CheckProfitLock()
{
   if(!EnableProfitLock) return;
   if(g_basketDirection == BASKET_NONE) return;

   double profit = CalculateBasketProfit(g_basketDirection);
   if(profit > g_basketPeakProfit)
      g_basketPeakProfit = profit;

   if(!g_profitLockArmed)
   {
      if(g_basketPeakProfit < ProfitLockActivation) return;
      g_profitLockArmed = true;
   }

   double giveback = g_basketPeakProfit - profit;
   double givebackLimit = g_basketPeakProfit * (ProfitLockGivebackPercent / 100.0);

   if(profit > 0 && giveback >= givebackLimit)
   {
      WriteTradeLog("TP", StringFormat("Profit lock triggered. Peak=%.2f Current=%.2f Giveback=%.2f (limit %.2f).",
                    g_basketPeakProfit, profit, giveback, givebackLimit));
      BeginBasketClose();
   }
}

void CheckForBasketTP()
{
   if(!UseVirtualBasketTP) return;

   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);

   bool tpHit = false;
   if(g_basketDirection == BASKET_BUY  && bid >= g_basketTP) tpHit = true;
   if(g_basketDirection == BASKET_SELL && ask <= g_basketTP) tpHit = true;
   if(!tpHit) return;

   double profit = CalculateBasketProfit(g_basketDirection);
   double threshold = GetMinimumProfitThreshold();

   if(profit >= threshold)
   {
      WriteTradeLog("TP", StringFormat("Basket TP reached. Average=%s TP=%s Profit=%.2f",
                    PxStr(g_weightedAverage), PxStr(g_basketTP), profit));
      BeginBasketClose();
   }
}

// When UseVirtualBasketTP=false the EA does not run its own coordinated
// close (see CheckForBasketTP above), so the basket needs a real exit
// mechanism instead: keep every position's broker-side TP in sync with the
// current weighted-average basket TP. Note this trades away two things the
// virtual mode provides: positions then close individually as each hits
// the shared TP price (not guaranteed atomically together), and the
// commission/swap-aware MinimumBasketProfit check is not applied, since
// the broker has no knowledge of it.
void SyncBrokerSideTakeProfit(ENUM_BASKET_DIRECTION direction)
{
   if(UseVirtualBasketTP) return;
   if(direction == BASKET_NONE || g_basketTP <= 0) return;

   BasketPosition arr[];
   int count = FindBasketPositions(direction, arr);

   for(int i = 0; i < count; i++)
   {
      if(!PositionSelectByTicket(arr[i].ticket)) continue;

      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      if(MathAbs(curTP - g_basketTP) <= g_tickSize / 2.0) continue; // already in sync

      if(!trade.PositionModify(arr[i].ticket, curSL, g_basketTP))
         LogError(StringFormat("Failed to sync broker-side TP on position %I64u, retcode=%u.",
                   arr[i].ticket, trade.ResultRetcode()));
   }
}

void BeginBasketClose()
{
   if(g_state == STATE_TP_CLOSING) return;
   g_state = STATE_TP_CLOSING;
   CancelAllPendingOrders();
   WriteTradeLog("CLOSE", "Beginning basket close for cycle " + g_cycleIdFull);
}

void ProcessBasketClosing()
{
   ENUM_BASKET_DIRECTION dir = g_basketDirection;
   BasketPosition arr[];
   int count = FindBasketPositions(dir, arr);

   if(count == 0)
   {
      WriteTradeLog("CLOSE", "All basket positions closed for cycle " + g_cycleIdFull);
      EnterCooldown();
      return;
   }

   for(int i = 0; i < count; i++)
   {
      bool ok = trade.PositionClose(arr[i].ticket, (ulong)MaximumSlippage);
      uint rc = trade.ResultRetcode();
      if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL))
         LogError(StringFormat("Failed to close position %I64u, retcode=%u. Will retry next tick.", arr[i].ticket, rc));
   }
}

void EnterCooldown()
{
   g_state = STATE_COOLDOWN;
   g_cooldownStart = TimeCurrent();
   g_basketDirection = BASKET_NONE;
   g_currentLevel = 0;
   g_maxLevelReached = false;
   g_averagingBlocked = false;
   g_averagingHardBlocked = false;
   g_maxLevelActionExecuted = false;
   g_basketLossActionExecuted = false;
   g_profitLockArmed = false;
   g_basketPeakProfit = 0;
   g_weightedAverage = 0;
   g_basketTP = 0;
   g_lastEntryPrice = 0;
   g_nextAveragingPrice = 0;
   WriteTradeLog("CYCLE", StringFormat("Entering cooldown for %d seconds.", CooldownAfterTP));
}

//======================================================================
// RISK CONTROL
//======================================================================
void CheckMaximumBasketLoss()
{
   if(!EnableMaximumBasketLoss) return;
   if(g_basketLossActionExecuted) return;

   double profit = CalculateBasketProfit(g_basketDirection);
   if(profit <= -MathAbs(MaximumBasketLoss))
   {
      g_basketLossActionExecuted = true;
      WriteTradeLog("RISK", StringFormat("Maximum basket loss reached. Profit=%.2f", profit));

      switch(MaximumBasketLossAction)
      {
         case MAXLOSS_CLOSE_BASKET:   BeginBasketClose(); break;
         case MAXLOSS_STOP_AVERAGING: g_averagingHardBlocked = true; break;
         case MAXLOSS_DISABLE_EA:     DisableEA("Maximum basket loss reached."); break;
      }
   }
}

void HandleMaxLevelReached()
{
   if(g_maxLevelActionExecuted) return;
   g_maxLevelActionExecuted = true;

   WriteTradeLog("RISK", StringFormat("Maximum martingale level reached (%d).", MaximumMartingaleLevels));

   switch(MaximumLevelAction)
   {
      case MAXLEVEL_STOP_AVERAGING: break; // wait for TP or recovery
      case MAXLEVEL_CLOSE_BASKET:   BeginBasketClose(); break;
      case MAXLEVEL_DISABLE_EA:     DisableEA("Maximum martingale level reached."); break;
   }
}

void DisableEA(string reason)
{
   if(g_eaDisabled) return;
   g_eaDisabled = true;
   WriteTradeLog("ERROR", reason + " EA disabled. Manual intervention required.");
   CancelAllPendingOrders();
   SaveGlobalState();
   g_state = STATE_ERROR;
}

//======================================================================
// FIBONACCI AVERAGING
//======================================================================
void CheckForAveraging()
{
   if(g_state != STATE_BUY_ACTIVE && g_state != STATE_SELL_ACTIVE) return;
   if(g_eaDisabled) return;

   if(g_currentLevel >= MaximumMartingaleLevels)
   {
      HandleMaxLevelReached();
      return;
   }

   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);

   bool triggered = false;
   if(g_basketDirection == BASKET_BUY  && bid <= g_nextAveragingPrice) triggered = true;
   if(g_basketDirection == BASKET_SELL && ask >= g_nextAveragingPrice) triggered = true;
   if(!triggered) return;

   int nextLevel = g_currentLevel + 1;
   double lot = GetFibonacciLot(nextLevel);

   if(!PassRiskChecksForAveraging(lot))
   {
      g_averagingBlocked = true;
      return;
   }

   g_averagingBlocked = false;
   OpenAveragingPosition(g_basketDirection, lot, nextLevel);
}

bool PassRiskChecksForAveraging(double lot)
{
   if(g_averagingHardBlocked) return false;
   if(g_eaDisabled)           return false;
   if(g_dailyLossTriggered || g_equityDrawdownTriggered) return false;

   if(lot > g_volMax)
   {
      WriteTradeLog("RISK", "Averaging blocked: next lot exceeds SYMBOL_VOLUME_MAX.");
      return false;
   }

   double currentLots = CalculateBasketLots(g_basketDirection);
   if(currentLots + lot > MaximumBasketLots + 0.0000001)
   {
      WriteTradeLog("RISK", "Averaging blocked: MaximumBasketLots would be exceeded.");
      return false;
   }

   if(EnableSpreadFilter && !IsSpreadAcceptable())
   {
      WriteTradeLog("RISK", "Averaging blocked: spread too high.");
      return false;
   }

   if(EnableTradingHours && !IsWithinTradingHours())
   {
      WriteTradeLog("RISK", "Averaging blocked: outside trading hours.");
      return false;
   }

   ENUM_ORDER_TYPE ot = (g_basketDirection == BASKET_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!IsMarginSafe(lot, ot))
   {
      WriteTradeLog("RISK", "Averaging blocked: insufficient margin or margin level would breach minimum.");
      return false;
   }

   if(!IsTradingAllowed())
   {
      WriteTradeLog("RISK", "Averaging blocked: trading not currently allowed.");
      return false;
   }

   return true;
}

void OpenAveragingPosition(ENUM_BASKET_DIRECTION direction, double lot, int level)
{
   string comment = BuildTradeComment("L" + IntegerToString(level));
   ulong posTicket = 0;
   double execPrice = 0, execVolume = 0;

   bool ok = (direction == BASKET_BUY) ?
             SendMarketOrder(true, lot, comment, posTicket, execPrice, execVolume) :
             SendMarketOrder(false, lot, comment, posTicket, execPrice, execVolume);

   if(!ok)
   {
      LogError(StringFormat("Failed to open averaging level %d. Will re-evaluate next tick.", level));
      return; // level state is not advanced; broker remains source of truth
   }

   WriteTradeLog("AVERAGE", StringFormat("%s Level %d opened. Lot=%.2f Price=%s",
                 DirectionToString(direction), level, execVolume, PxStr(execPrice)));

   RecalculateBasketMetrics(direction);
   SyncBrokerSideTakeProfit(direction);
   WriteTradeLog("BASKET", StringFormat("Average=%s TP=%s", PxStr(g_weightedAverage), PxStr(g_basketTP)));

   if(g_currentLevel >= MaximumMartingaleLevels)
      HandleMaxLevelReached();
}

double GetFibonacciLot(int level)
{
   int idx = level - 1;
   if(idx < 0) idx = 0;
   if(idx >= g_fibCount) idx = g_fibCount - 1;
   return g_fibLots[idx];
}

//======================================================================
// NORMALIZATION HELPERS
//======================================================================
double NormalizeVolume(double volume)
{
   if(g_volStep <= 0) return volume;
   double steps = MathFloor(volume / g_volStep + 0.0000001);
   double vol = steps * g_volStep;
   if(vol < g_volMin) vol = g_volMin;
   if(vol > g_volMax) vol = g_volMax;
   return NormalizeDouble(vol, g_volDigits);
}

double NormalizePriceToTick(double price)
{
   double tickSize = (g_tickSize > 0) ? g_tickSize : g_point;
   double normalized = MathRound(price / tickSize) * tickSize;
   return NormalizeDouble(normalized, g_digits);
}

string PxStr(double price)
{
   return DoubleToString(price, g_digits);
}

//======================================================================
// FILTERS
//======================================================================
bool IsSpreadAcceptable()
{
   if(!EnableSpreadFilter) return true;
   double spread = SymbolInfoDouble(g_symbol, SYMBOL_ASK) - SymbolInfoDouble(g_symbol, SYMBOL_BID);
   return spread <= MaximumSpread;
}

int ParseTimeToMinutes(string t)
{
   string parts[];
   int n = StringSplit(t, StringGetCharacter(":", 0), parts);
   if(n < 2) return 0;
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   return h * 60 + m;
}

bool IsWithinTradingHours()
{
   if(!EnableTradingHours) return true;

   int startMin = ParseTimeToMinutes(TradingStartTime);
   int endMin   = ParseTimeToMinutes(TradingEndTime);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMin = dt.hour * 60 + dt.min;

   if(startMin <= endMin)
      return (nowMin >= startMin && nowMin <= endMin);
   else
      return (nowMin >= startMin || nowMin <= endMin);
}

// Always-on safety net, independent of EnableTradingHours/CloseBasketAtSessionEnd
// (which are the user-configurable window): reads the broker's own trading-session
// schedule for the symbol and reports true once "now" is within
// MARKET_CLOSE_SAFETY_MINUTES of today's real session close - e.g. the daily
// close, or the Friday close ahead of the weekend gap. No input is exposed for
// this because the correct close time is broker/server-specific data, not
// something to hand-configure; if the broker/test data doesn't expose session
// times, this safely reports false rather than guessing.
bool IsNearMarketClose()
{
   MqlDateTime dtNow;
   TimeToStruct(TimeCurrent(), dtNow);
   int secondsNow = dtNow.hour * 3600 + dtNow.min * 60 + dtNow.sec;

   for(uint session = 0; session < 5; session++)
   {
      datetime sessFrom = 0, sessTo = 0;
      if(!SymbolInfoSessionTrade(g_symbol, (ENUM_DAY_OF_WEEK)dtNow.day_of_week, session, sessFrom, sessTo))
         break;

      MqlDateTime dtFrom, dtTo;
      TimeToStruct(sessFrom, dtFrom);
      TimeToStruct(sessTo, dtTo);
      int secFrom = dtFrom.hour * 3600 + dtFrom.min * 60 + dtFrom.sec;
      int secTo   = dtTo.hour   * 3600 + dtTo.min   * 60 + dtTo.sec;

      if(secondsNow >= secFrom && secondsNow <= secTo)
         return (secTo - secondsNow) <= MARKET_CLOSE_SAFETY_MINUTES * 60;
   }

   return false; // not inside any known session right now - nothing to guard against
}

bool IsVolatilityAcceptable()
{
   if(!EnableATRFilter) return true;
   if(g_atrHandle == INVALID_HANDLE) return true;

   double buf[1];
   if(CopyBuffer(g_atrHandle, 0, 0, 1, buf) <= 0) return true;
   return buf[0] <= MaximumATR;
}

bool IsMarginSafe(double volume, ENUM_ORDER_TYPE orderType)
{
   double price = (orderType == ORDER_TYPE_BUY) ?
                   SymbolInfoDouble(g_symbol, SYMBOL_ASK) :
                   SymbolInfoDouble(g_symbol, SYMBOL_BID);

   double marginRequired;
   if(!OrderCalcMargin(orderType, g_symbol, volume, price, marginRequired))
      return false;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(marginRequired > freeMargin)
   {
      g_marginProtectionTriggered = true;
      return false;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double usedMarginAfter = AccountInfoDouble(ACCOUNT_MARGIN) + marginRequired;

   if(usedMarginAfter > 0)
   {
      double projectedLevel = equity / usedMarginAfter * 100.0;
      if(projectedLevel < MinimumMarginLevelPercent)
      {
         g_marginProtectionTriggered = true;
         return false;
      }
   }

   g_marginProtectionTriggered = false;
   return true;
}

bool IsTradingAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))            return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))    return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))     return false;

   ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY) return false;

   return true;
}

//======================================================================
// GLOBAL POSITION CLOSE HELPERS (used by emergency / equity protection)
//======================================================================
void CloseAllEAPositions()
{
   CloseBasketDirection(BASKET_BUY);
   CloseBasketDirection(BASKET_SELL);
}

void CloseBasketDirection(ENUM_BASKET_DIRECTION direction)
{
   BasketPosition arr[];
   int count = FindBasketPositions(direction, arr);
   for(int i = 0; i < count; i++)
   {
      bool ok = trade.PositionClose(arr[i].ticket, (ulong)MaximumSlippage);
      if(!ok)
         LogError(StringFormat("Failed to close position %I64u, retcode=%u.", arr[i].ticket, trade.ResultRetcode()));
   }
}

//======================================================================
// IDENTIFICATION / LOGGING
//======================================================================
void GenerateNewCycleId()
{
   g_cycleCounter++;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_cycleIdFull = StringFormat("%04d%02d%02d_%02d%02d%02d_%03d",
                                 dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec, g_cycleCounter % 1000);
   g_cycleId = StringFormat("%02d%02d%02d_%03d", dt.hour, dt.min, dt.sec, g_cycleCounter % 1000);
   SaveGlobalState();
}

string BuildTradeComment(string tag)
{
   string prefix = TradeComment;
   if(StringLen(prefix) > 8) prefix = StringSubstr(prefix, 0, 8);
   string c = prefix + "|" + g_cycleId + "|" + tag;
   if(StringLen(c) > 31) c = StringSubstr(c, 0, 31);
   return c;
}

string GetAccountMarginModeString()
{
   ENUM_ACCOUNT_MARGIN_MODE mode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   switch(mode)
   {
      case ACCOUNT_MARGIN_MODE_RETAIL_HEDGING: return "HEDGING";
      case ACCOUNT_MARGIN_MODE_RETAIL_NETTING: return "NETTING";
      case ACCOUNT_MARGIN_MODE_EXCHANGE:       return "EXCHANGE";
   }
   return "UNKNOWN";
}

string StateToString(EAState s)
{
   switch(s)
   {
      case STATE_IDLE:                 return "IDLE";
      case STATE_WAITING_FOR_BREAKOUT: return "WAITING_FOR_BREAKOUT";
      case STATE_BUY_ACTIVE:           return "BUY_ACTIVE";
      case STATE_SELL_ACTIVE:          return "SELL_ACTIVE";
      case STATE_TP_CLOSING:           return "TP_CLOSING";
      case STATE_COOLDOWN:             return "COOLDOWN";
      case STATE_RISK_STOP:            return "RISK_STOP";
      case STATE_EMERGENCY_BOTH_SIDES: return "EMERGENCY_BOTH_SIDES";
      case STATE_ERROR:                return "ERROR";
   }
   return "UNKNOWN";
}

string DirectionToString(ENUM_BASKET_DIRECTION d)
{
   if(d == BASKET_BUY)  return "BUY";
   if(d == BASKET_SELL) return "SELL";
   return "NONE";
}

void WriteTradeLog(string category, string message)
{
   Print("[" + category + "] " + message);
}

void LogError(string message)
{
   WriteTradeLog("ERROR", message);
}

//======================================================================
// DASHBOARD
//======================================================================
void AddDashLine(string text)
{
   if(g_dashLineCount < 100)
      g_dashLines[g_dashLineCount++] = text;
}

void RenderDashboard()
{
   long chartId = 0;
   for(int i = 0; i < g_dashLineCount; i++)
   {
      string name = DASH_PREFIX + IntegerToString(i);
      if(ObjectFind(chartId, name) < 0)
      {
         ObjectCreate(chartId, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(chartId, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(chartId, name, OBJPROP_XDISTANCE, DASH_X);
         ObjectSetInteger(chartId, name, OBJPROP_YDISTANCE, DASH_Y_START + i * DASH_LINE_HEIGHT);
         ObjectSetString(chartId, name, OBJPROP_FONT, DASH_FONT);
         ObjectSetInteger(chartId, name, OBJPROP_FONTSIZE, DASH_FONT_SIZE);
         ObjectSetInteger(chartId, name, OBJPROP_COLOR, clrWhite);
         ObjectSetInteger(chartId, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, name, OBJPROP_HIDDEN, true);
         ObjectSetInteger(chartId, name, OBJPROP_BACK, false);
      }
      ObjectSetString(chartId, name, OBJPROP_TEXT, g_dashLines[i]);
   }
   ChartRedraw(chartId);
}

void RemoveDashboard()
{
   long chartId = 0;
   for(int i = 0; i < 100; i++)
      ObjectDelete(chartId, DASH_PREFIX + IntegerToString(i));
}

void UpdateDashboard()
{
   g_dashLineCount = 0;

   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double spread = ask - bid;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double dailyPL = (g_startOfDayEquity > 0) ? equity - g_startOfDayEquity : 0;
   double dailyPLPercent = (g_startOfDayEquity > 0) ? dailyPL / g_startOfDayEquity * 100.0 : 0;
   double ddPercent = (g_equityBaseline > 0) ? (g_equityBaseline - equity) / g_equityBaseline * 100.0 : 0;
   double floatingPL = CalculateBasketProfit(BASKET_BUY) + CalculateBasketProfit(BASKET_SELL);
   double basketPL = (g_basketDirection != BASKET_NONE) ? CalculateBasketProfit(g_basketDirection) : 0;
   double totalLots = CalculateBasketLots(BASKET_BUY) + CalculateBasketLots(BASKET_SELL);
   int totalPositions = CountBasketPositions(BASKET_BUY) + CountBasketPositions(BASKET_SELL);
   int nextLevel = (int)MathMin((double)(g_currentLevel + 1), (double)MaximumMartingaleLevels);
   double nextLot = GetFibonacciLot(nextLevel);

   AddDashLine("== FIBONACCI BREAKOUT EA ==");
   AddDashLine("Symbol: " + g_symbol);
   AddDashLine("Account Type: " + GetAccountMarginModeString() + (g_isHedgingAccount ? "" : " (WARNING)"));
   AddDashLine("EA State: " + StateToString(g_state));
   AddDashLine("--------------------------------");
   AddDashLine("Bid: " + PxStr(bid) + "   Ask: " + PxStr(ask));
   AddDashLine("Spread: " + PxStr(spread));
   AddDashLine("--------------------------------");
   AddDashLine("Cycle ID: " + g_cycleIdFull);
   AddDashLine("Direction: " + DirectionToString(g_basketDirection));
   AddDashLine(StringFormat("Current Level: %d / %d", g_currentLevel, MaximumMartingaleLevels));
   AddDashLine("Total Positions: " + IntegerToString(totalPositions));
   AddDashLine(StringFormat("Total Lots: %.2f", totalLots));
   AddDashLine("--------------------------------");
   AddDashLine("Weighted Average: " + PxStr(g_weightedAverage));
   AddDashLine("Basket TP: " + PxStr(g_basketTP));
   AddDashLine("Next Averaging Price: " + PxStr(g_nextAveragingPrice));
   AddDashLine("Grid Mode: " + (UseATRGrid ?
               StringFormat("ATR (Entry=%s Grid=%s TP=%s)", PxStr(g_effEntryDistance), PxStr(g_effGridStep), PxStr(g_effBasketTPDistance)) :
               "Fixed"));
   AddDashLine(StringFormat("Next Fibonacci Lot: %.2f", nextLot));
   AddDashLine("--------------------------------");
   AddDashLine(StringFormat("Floating P/L: %.2f", floatingPL));
   AddDashLine(StringFormat("Basket P/L: %.2f", basketPL));
   AddDashLine("Profit Lock: " + (!EnableProfitLock ? "OFF" : (g_profitLockArmed ? StringFormat("ARMED (peak %.2f)", g_basketPeakProfit) : StringFormat("watching (peak %.2f)", g_basketPeakProfit))));
   AddDashLine(StringFormat("Equity: %.2f", equity));
   AddDashLine(StringFormat("Balance: %.2f", balance));
   AddDashLine(StringFormat("Free Margin: %.2f", freeMargin));
   AddDashLine(StringFormat("Margin Level: %.2f%%", marginLevel));
   AddDashLine("--------------------------------");
   AddDashLine(StringFormat("Daily P/L: %.2f (%.2f%%)", dailyPL, dailyPLPercent));
   AddDashLine(StringFormat("Drawdown: %.2f%%", ddPercent));
   AddDashLine("--------------------------------");
   AddDashLine("Spread Status: " + (IsSpreadAcceptable() ? "OK" : "BLOCKED"));
   AddDashLine("Margin Status: " + (g_marginProtectionTriggered ? "BLOCKED" : "OK"));
   AddDashLine("Risk Status: " + (g_eaDisabled ? "DISABLED" :
                                  (g_dailyLossTriggered ? "DAILY LOSS STOP" :
                                  (g_equityDrawdownTriggered ? "EQUITY DD STOP" : "OK"))));
   AddDashLine("Trading Hours: " + (EnableTradingHours ? (IsWithinTradingHours() ? "OPEN" : "CLOSED") : "N/A"));
   AddDashLine("Market Close Guard: " + (IsNearMarketClose() ? "CLOSING SOON" : "OK"));
   AddDashLine("ATR Status: " + (EnableATRFilter ? (IsVolatilityAcceptable() ? "OK" : "BLOCKED") : "N/A"));
   AddDashLine("Averaging Blocked: " + (g_averagingHardBlocked ? "YES (hard)" : (g_averagingBlocked ? "YES" : "NO")));

   RenderDashboard();
}
//+------------------------------------------------------------------+
