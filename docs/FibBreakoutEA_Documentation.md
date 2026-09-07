# FibBreakoutEA — MT5 XAUUSD Fibonacci Breakout + Averaging EA

Source: `MQL5/Experts/FibBreakoutEA.mq5`

## 1. Overview

FibBreakoutEA implements a breakout-and-average strategy:

1. Place a `BUY STOP` and a `SELL STOP` around the current market price.
2. Whichever triggers first becomes the active basket direction; the opposite
   pending order is cancelled immediately.
3. If price moves against the basket, additional positions are added using a
   Fibonacci lot sequence at fixed `GridStep` intervals, one level per tick
   at most.
4. The basket's weighted-average entry price is recalculated after every
   fill; the basket take-profit is `average ± BasketTPDistance`.
5. When price reaches the basket TP **and** the real net profit (including
   swap/commission) meets `MinimumBasketProfit`, every position in the
   basket is closed together.
6. The EA waits `CooldownAfterTP` seconds, then starts a new cycle using
   fresh market prices.

The core mechanism (breakout → cancel opposite → average → weighted TP →
close all → cooldown → restart) is never altered by any of the optional risk
filters; they only decide *whether* a step is allowed to happen, never
*what* the step does.

The EA is written for **XAUUSD on a retail hedging account**, but does not
hard-code the symbol name and works with any broker's suffix convention
(`XAUUSD`, `XAUUSDm`, `XAUUSD.a`, `XAUUSD.pro`, ...).

## 2. Account type handling

At `OnInit()`, `ValidateEnvironment()` reads `ACCOUNT_MARGIN_MODE` and shows
it on the dashboard (`HEDGING` / `NETTING` / `EXCHANGE`):

- **Hedging accounts** (`ACCOUNT_MARGIN_MODE_RETAIL_HEDGING`): fully
  supported — this is the intended mode, since the strategy requires
  multiple simultaneous same-direction positions.
- **Netting or exchange accounts**: the EA logs a `WARNING` and, if
  `RequireHedgingAccount = true` (default), sets the internal state to
  `STATE_ERROR` and refuses to place any trade. The EA still loads and the
  dashboard still displays (so the account-type mismatch is visible), but
  every trading path is gated behind `g_state != STATE_ERROR`. Netting
  reconstruction from historical deals was deliberately **not**
  implemented — see *Known limitations*.

## 3. Price distance model

All of `EntryDistance`, `GridStep`, and `BasketTPDistance` are **price
units**, not pips (e.g. `0.50` = $0.50 on XAUUSD). Every computed price is
passed through:

```
double NormalizePriceToTick(double price)
```

which rounds to the broker's `SYMBOL_TRADE_TICK_SIZE` (falling back to
`SYMBOL_POINT` if the tick size is unavailable) and then to `SYMBOL_DIGITS`.
Before pending orders are sent, `ValidateStopDistances()` checks the
requested distance against `SYMBOL_TRADE_STOPS_LEVEL` and
`SYMBOL_TRADE_FREEZE_LEVEL`; if the distance is too small it is either
auto-adjusted (`AutoAdjustInvalidStopDistance = true`, default) or the cycle
is rejected with a logged reason.

## 4. State machine

```
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
```

| State | Meaning |
|---|---|
| `IDLE` | No basket, no pending orders — eligible to start a new cycle. |
| `WAITING_FOR_BREAKOUT` | Both (or one, if `AllowOneSidedCycle`) pending stop orders are live. |
| `BUY_ACTIVE` / `SELL_ACTIVE` | A basket is open in that direction; averaging/TP management runs every tick. |
| `TP_CLOSING` | Basket TP (or a risk action) triggered a close; the EA loops closing each position until the basket is flat. |
| `COOLDOWN` | Basket just closed; waiting `CooldownAfterTP` seconds before a new cycle. |
| `RISK_STOP` | Daily loss or equity drawdown blocked new cycles while no basket is active. |
| `EMERGENCY_BOTH_SIDES` | Both stop orders triggered before the opposite could be cancelled (fast market). Normal logic is fully suspended. |
| `ERROR` | Hard validation failure (wrong account type with `RequireHedgingAccount=true`, invalid symbol/inputs, or `DisableEA()` was called). No trading occurs. |

**Broker state always wins.** Every tick, `ReconcileBasketState()` re-scans
live positions and pending orders (filtered by `Symbol + MagicNumber`) and
corrects `g_state` to match reality — this is what makes the EA safe across
restarts, reconnects, and any external order rejection that the EA's
in-memory expectations did not foresee. `RebuildStateFromBroker()` runs the
same logic once at `OnInit()` for restart recovery (see §8).

## 5. Trade lifecycle

1. **`StartNewCycle()`** (from `IDLE`): validated by `CanStartNewCycle()`
   (no EA positions/orders, trading allowed, spread/hours/ATR/margin OK).
   Computes `Ask+EntryDistance` / `Bid-EntryDistance`, normalizes, validates
   stop distance, generates a new Cycle ID, and calls
   `PlaceInitialPendingOrders()`.
2. **`PlaceInitialPendingOrders()`**: sends the BUY STOP, verifies the
   result (`ResultRetcode()` + `OrderSelect()`), then the SELL STOP. If the
   second leg fails and `AllowOneSidedCycle = false` (default), the first
   leg is cancelled and the cycle is aborted — never left half-open.
3. **Trigger** (`ReconcileBasketState()` sees a position appear): the
   opposite pending order is cancelled (`CancelSellStop()`/`CancelBuyStop()`),
   and `ActivateBasket()` records the actual filled price (via the deal
   history, never the requested pending price) and enters
   `BUY_ACTIVE`/`SELL_ACTIVE`.
4. **Averaging** (`CheckForAveraging()`): once per tick, if price has moved
   `GridStep` beyond `g_nextAveragingPrice` (anchored to the *actual* last
   fill price, not the theoretical grid), the EA checks
   `PassRiskChecksForAveraging()` (level cap, lot cap, spread, hours,
   margin, trading-allowed) and if all pass, opens exactly one more
   position at `GetFibonacciLot(level)`. Only one level can open per tick.
5. **TP** (`CheckForBasketTP()`): every tick, `RecalculateBasketMetrics()`
   recomputes the weighted average and TP from live positions. When Bid
   (BUY) / Ask (SELL) reaches TP **and** `CalculateBasketProfit()` (P/L +
   swap + commission) meets the configured minimum, `BeginBasketClose()`
   is called.
6. **Close** (`ProcessBasketClosing()`): loops the actual open positions
   and closes each one individually, re-scanning after every attempt;
   only when the matching position count reaches zero does the EA call
   `EnterCooldown()`.
7. **Cooldown → new cycle**: after `CooldownAfterTP` seconds, state returns
   to `IDLE` and step 1 repeats with brand-new market prices.

### 5a. Two take-profit modes (`UseVirtualBasketTP`)

- **`UseVirtualBasketTP = true` (default, preferred).** `CheckForBasketTP()`
  runs every tick: it computes the weighted average and TP from live
  positions, and only when price reaches the TP **and** real net profit
  (P/L + swap + commission) meets `MinimumBasketProfit` does it call
  `BeginBasketClose()`, which closes every basket position together. No
  broker-side TP is ever placed on the individual positions (`tp=0` at
  open) — the EA is the only thing that can close the basket at a profit.
- **`UseVirtualBasketTP = false`.** The EA does not run its own closing
  logic at all. Instead, `SyncBrokerSideTakeProfit()` keeps every basket
  position's broker-side TP field set to the current basket TP price —
  called whenever a basket activates, whenever a new averaging position
  opens, and every tick while a basket is active (so a shift in the
  weighted average from a new fill immediately re-prices the TP on the
  *existing* positions too, not just the newest one). The broker then
  closes each position as its TP is hit. Because every position shares the
  same TP price, they will typically all fill within the same tick/moment
  in a normal market — but this is **not** the same guarantee as the
  virtual mode: positions can close individually rather than atomically
  together, and `MinimumBasketProfit`/commission-aware verification is
  **not** applied in this mode (the broker's TP order has no visibility
  into swap/commission). Choose this mode only if you specifically want a
  broker-enforced TP that survives the EA/terminal being offline; the
  trade-off is losing the coordinated-close and profit-verification
  guarantees of virtual mode.

### 5b. Profit lock (`EnableProfitLock`)

Both TP modes evaluate against whatever tick they're given, on the tick
they're given it. If price spikes far past `BasketTPDistance` and back down
within a small number of ticks — a real fast-market gap, or (far more
commonly in Strategy Tester) an artifact of synthetic/low-quality tick
modeling for a historical bar — the basket can end up closing near the bare
minimum TP instead of near the spike, simply because no tick at the spike
was ever delivered while the basket was still open. This is not a defect in
`CheckForBasketTP()` itself (it closes on the very first qualifying tick it
receives, with no retracement-waiting logic anywhere) — it's a consequence
of what tick data the basket was actually evaluated against. See §13 for
how to check whether that's what's happening in your test.

`CheckProfitLock()` adds an independent, always-on-top-of-either-TP-mode
safeguard: it tracks the basket's peak floating profit
(`CalculateBasketProfit()`) every tick. Once that peak clears
`ProfitLockActivation`, the lock arms; from then on, if profit pulls back
from the peak by `ProfitLockGivebackPercent`%, the basket closes
immediately via `BeginBasketClose()` — capturing most of an unexpected
favorable move instead of risking it all being given back. It never closes
at a loss (guarded by `profit > 0`), and it's independent of
`UseVirtualBasketTP` so it backstops broker-side TP mode too.

Off by default (`EnableProfitLock=false`) so it doesn't change existing
behavior. Set `ProfitLockActivation` at or above your typical
`BasketTPDistance`-implied profit, so it only arms on genuinely unusual
spikes rather than interfering with ordinary TP-sized wins — arming too low
means it can force an exit slightly below your normal TP target in choppy
conditions. The dashboard's "Profit Lock" line shows `OFF`, `watching
(peak …)` before it arms, or `ARMED (peak …)` once armed.

## 6. Risk management (checked before every trade)

`PassRiskChecksForAveraging()` and `CanStartNewCycle()` gate every new
order on, in order: EA disabled / daily-loss / equity-DD flags → level cap
→ basket lot cap → spread filter → trading hours → margin safety
(`IsMarginSafe`, using `OrderCalcMargin` and `MinimumMarginLevelPercent`) →
general trading-allowed checks. If any check fails, the trade is simply not
sent (never overridden) and the reason is logged.

- **Maximum martingale level** (`MaximumMartingaleLevels`,
  `MaximumLevelAction`): once the open position count reaches the cap,
  `HandleMaxLevelReached()` fires exactly once per basket and either stops
  averaging (default), force-closes the basket, or disables the EA.
- **Maximum basket loss** (`EnableMaximumBasketLoss`, `MaximumBasketLoss`,
  `MaximumBasketLossAction`): checked every tick via
  `CheckMaximumBasketLoss()` against the real net basket P/L.
- **Equity drawdown** (`EnableEquityProtection`,
  `MaximumEquityDrawdownPercent`): measured against the equity baseline
  captured at EA start. On breach, the EA cancels all pending orders,
  force-closes **only its own** positions, and disables itself
  permanently (until the chart/EA is reloaded).
- **Daily loss** (`EnableDailyLossLimit`, `MaximumDailyLossPercent`):
  measured against equity at server-day start. On breach, new cycles and
  averaging are blocked until the next server day, at which point the flag
  clears automatically.
- **Margin** (`MinimumMarginLevelPercent`): every prospective trade's
  margin requirement is checked against free margin and the projected
  post-trade margin level.
- **Spread / ATR / trading hours**: pure pre-trade filters; they never
  touch an already-open basket's TP or emergency management.

Manual trades and other EAs' trades are never touched — every position and
order query filters strictly on `Symbol() + MagicNumber`.

## 7. Emergency both-sides handling

If both stop orders fill before the opposite could be cancelled (fast/gappy
market), `ReconcileBasketState()` detects positions on both sides and
switches to `STATE_EMERGENCY_BOTH_SIDES`, which fully suspends normal
averaging/TP logic. `BothSidesEmergencyMode` selects the response:

- `0` — close both baskets immediately, then cooldown.
- `1` — close the losing side, then resume normal single-direction
  management of the remaining side.
- `2` — disable the EA and require manual intervention.

## 8. Restart recovery

`RebuildStateFromBroker()` runs once at `OnInit()`:

- Positions on both sides → `EMERGENCY_BOTH_SIDES`.
- Positions on one side only → recompute level/average/TP/next-averaging
  price from the live positions and resume `BUY_ACTIVE`/`SELL_ACTIVE`,
  cancelling any stray opposite pending order.
- No positions but a pending stop order exists → `WAITING_FOR_BREAKOUT`
  (the pending-expiration clock is re-anchored to the order's actual setup
  time via `GetOldestPendingOrderTime()`, so a restart cannot silently
  extend the expiration window).
- Nothing at all → `IDLE`, ready for a new cycle.

The EA never places a duplicate BUY STOP/SELL STOP after a restart, because
`CanStartNewCycle()` refuses to start while any EA pending order or
position already exists.

`GlobalVariable`s (`FibEA_<symbol>_<magic>_Disabled/EquityDD/CycleCounter`)
persist the "permanently disabled" and "equity drawdown tripped" flags and
the cycle counter across terminal restarts, but broker
positions/orders remain the primary source of truth for everything else
(level, average, TP, direction).

## 9. Dashboard

An on-chart label panel (`OBJ_LABEL` objects, top-left) refreshes every
tick (throttled to ~5/sec) and every second via `OnTimer()`, showing:
symbol, account type (with a hedging-mismatch warning), EA state, bid/ask/
spread, cycle ID, direction, level/max level, position count, total lots,
weighted average, basket TP, next averaging price, next Fibonacci lot,
floating/basket P/L, equity/balance/free margin/margin level, daily P/L,
drawdown %, and status flags for spread/margin/risk/trading-hours/ATR/
averaging-blocked.

## 10. Input parameter reference

| Group | Input | Default | Meaning |
|---|---|---|---|
| General | `MagicNumber` | 20260905 | Identifies this EA's own trades. |
| | `TradeComment` | FibBreakoutEA | Prefix used in order/position comments. |
| | `RequireHedgingAccount` | true | Block trading on non-hedging accounts. |
| | `AllowedSymbol` | "" (blank) | Restrict to a specific symbol/prefix; blank = chart symbol. |
| Entry | `EntryDistance` | 0.50 | BUY/SELL STOP distance from market (price units). |
| Take Profit | `BasketTPDistance` | 0.50 | TP distance from the weighted average. |
| | `MinimumBasketProfit` | 0.00 | Minimum net profit required to actually close at TP. |
| | `MinimumBasketProfitMode` | Currency | Currency / % of equity / price-distance only. |
| | `UseVirtualBasketTP` | true | `true`: EA closes the whole basket together once real net profit (incl. swap/commission) meets `MinimumBasketProfit`. `false`: EA instead keeps a broker-side TP order on every position, synced to the current basket TP price — positions then close individually as the broker fills each TP, without the commission-aware profit check. See §5a. |
| | `EnableProfitLock` | false | Enable the peak-profit giveback lock — closes the basket if profit pulls back too far from its peak. See §5b. |
| | `ProfitLockActivation` | 1.00 | Floating basket profit (currency) that arms the lock. |
| | `ProfitLockGivebackPercent` | 30.0 | % pullback from peak profit, once armed, that forces an immediate close. |
| Averaging | `GridStep` | 0.50 | Distance between averaging levels. |
| | `InitialLot` | 0.01 | Level-1 lot size; seeds the Fibonacci sequence. |
| | `MaximumMartingaleLevels` | 6 | Hard cap on basket size (includes level 1). |
| | `MaximumBasketLots` | 0.35 | Hard cap on total basket volume. |
| | `MaximumLevelAction` | Stop averaging | Action once the level cap is hit. |
| Risk | `EnableMaximumBasketLoss` | true | Enable the basket-loss cap. |
| | `MaximumBasketLoss` | 100.0 | Basket loss (currency) that triggers `MaximumBasketLossAction`. |
| | `MaximumBasketLossAction` | Close basket | Action at max basket loss. |
| | `EnableEquityProtection` | true | Enable equity drawdown protection. |
| | `MaximumEquityDrawdownPercent` | 10.0 | % drawdown from the init-time equity baseline that disables the EA. |
| | `EnableDailyLossLimit` | true | Enable the daily loss limit. |
| | `MaximumDailyLossPercent` | 5.0 | % loss from day-start equity that halts new cycles for the day. |
| | `MinimumMarginLevelPercent` | 300.0 | Minimum acceptable projected margin level before any trade. |
| Filters | `EnableSpreadFilter` | true | Enable the max-spread filter. |
| | `MaximumSpread` | 0.50 | Max acceptable spread (price units). |
| | `EnableATRFilter` | false | Optional volatility filter for **new cycles only**. |
| | `ATRPeriod` | 14 | ATR period. |
| | `MaximumATR` | 5.00 | ATR ceiling for starting a new cycle. |
| | `EnableTrendFilter` | false | Optional EMA trend filter for **new cycles only**. |
| | `TrendEMAFastPeriod` / `TrendEMASlowPeriod` | 20 / 50 | EMA periods; fast>slow allows BUY-only, fast<slow allows SELL-only. |
| Trading Hours | `EnableTradingHours` | false | Restrict new entries/averaging to a time window. |
| | `TradingStartTime` / `TradingEndTime` | 00:00 / 23:59 | Server-time HH:MM window (overnight wrap supported). |
| | `CloseBasketAtSessionEnd` | false | Force-close an active basket when the window ends. |
| Orders | `EnablePendingExpiration` | true | Cancel untriggered pendings after a timeout. |
| | `PendingExpirationMinutes` | 60 | Timeout in minutes. |
| | `AutoAdjustInvalidStopDistance` | true | Auto-widen distances that violate broker stop/freeze levels. |
| | `AllowOneSidedCycle` | false | Continue if only one pending leg can be placed. |
| Execution | `MaximumSlippage` | 20 | Deviation in points for market orders/closes. |
| | `MaximumRetryAttempts` | 3 | Retry cap for retryable broker errors. |
| | `RetryDelayMilliseconds` | 500 | Delay between retries. |
| Recovery | `BothSidesEmergencyMode` | Close both | Behaviour when both breakout orders fill. |
| | `CooldownAfterTP` | 5 | Seconds to wait after a basket closes before the next cycle. |

`MagicNumber` should **not** be optimized. All other numeric inputs listed
above are safe optimization candidates in Strategy Tester.

## 11. Strategy Tester instructions

1. Open **Strategy Tester** (View → Strategy Tester or `Ctrl+R`).
2. Select **FibBreakoutEA**, symbol **XAUUSD** (or your broker's variant),
   and set **Execution mode: Every tick based on real ticks** — this
   strategy's averaging/TP logic depends on accurate intrabar price
   movement, so bar-based modeling will misrepresent grid fills.
3. Under **Trade** settings for the test, make sure the tester account is
   configured for **hedging** (Tester → Settings, or use a hedging-mode
   test deposit) — under netting the tester will merge same-direction
   trades and the basket math will not reflect live behaviour.
4. Recommended initial test defaults (already the EA's shipped defaults):
   `EntryDistance=0.50`, `GridStep=0.50`, `BasketTPDistance=0.50`,
   `InitialLot=0.01`, `MaximumMartingaleLevels=6`,
   `MaximumBasketLots=0.35`, `MaximumBasketLoss=100`,
   `MaximumEquityDrawdownPercent=10`, `MaximumDailyLossPercent=5`.
   `MaximumBasketLots` is sized so level 6 (cumulative 0.32 lots) is
   actually reachable — it used to be 0.25, which silently capped the
   basket at level 5 regardless of `MaximumMartingaleLevels`.
5. Test across the scenarios in spec §48: trending bull/bear, sideways,
   high/low volatility, high spread, gap-heavy periods (weekend
   opens/news), and deliberately small `MaximumMartingaleLevels`/
   `MaximumBasketLoss` to exercise the risk-stop paths. Use the tester's
   "Forward" and multiple random-delay passes to probe the both-sides
   emergency path under simulated latency.
6. For restart-recovery testing, this must be done on a **live/demo**
   terminal (the Strategy Tester does not restart mid-test): attach the EA,
   let a basket build, then remove and re-add the EA (or restart the
   terminal) and confirm the dashboard recovers the correct level/average/
   TP without placing duplicate pending orders.

## 12. Evaluating the backtest report

Do not judge this strategy by win rate — a Fibonacci/martingale-style
averaging system produces a very high hit rate on small wins and a rare but
severe tail loss during a prolonged one-directional move. Instead, review:

- **Profit factor** and **expected payoff** — should be evaluated together
  with maximum drawdown, not in isolation.
- **Maximum drawdown** (equity and balance) — the single most important
  number for this style of strategy.
- **Maximum consecutive losses** and **worst basket loss** — check these
  against `MaximumBasketLoss`/`MaximumEquityDrawdownPercent` to confirm the
  caps actually bound real-world losses as configured.
- **Maximum Fibonacci level reached** and **maximum basket lots** — confirm
  they never exceeded `MaximumMartingaleLevels`/`MaximumBasketLots` (the log
  will show `[RISK] Maximum martingale level reached` /
  `MaximumBasketLots would be exceeded` entries if the caps were hit).
- **Average basket duration**, **average winning basket**, **average
  losing basket**, **recovery factor**, **net profit**, and **return on
  equity** — use these to judge whether the TP distance and grid spacing
  are well matched to the instrument's typical volatility.
- Total trades / winning vs losing cycles — a cycle is "won" when a basket
  reaches TP with net profit ≥ `MinimumBasketProfit`, and "lost" when it is
  closed by a risk control (`MaximumBasketLossAction` / max-level /
  emergency) at a loss.

## 13. Known limitations

- **Strategy Tester tick quality directly affects TP accuracy.** `CheckForBasketTP()`
  closes on the first tick that satisfies its condition — there is no
  retracement-waiting logic. If a basket appears to spike well past
  `BasketTPDistance` on the chart and then closes near the bare minimum
  instead, that near-certainly means the spike was never delivered to
  `OnTick()` as an actual simulated tick — it's a synthetic-modeling
  artifact of the historical bar, not a decision the EA made. Check the
  **Modelling quality %** in the tester's results tab (bottom of the report)
  — well under 99% confirms coarse/synthetic tick reconstruction for that
  run. Use "Every tick based on real ticks" and, if still affected, verify
  your broker actually has genuine tick-level history for that symbol and
  period (Tools → History Center). `EnableProfitLock` (§5b) mitigates the
  impact regardless of the underlying cause, but cannot fix data that was
  never generated at the true price.
- **Netting accounts are not reconstructed from deal history.** The spec's
  preferred fallback (§ Important Account Type) — reconstructing
  per-level state from netting deal history — was intentionally not
  implemented; instead the EA blocks trading on non-hedging accounts by
  default (`RequireHedgingAccount=true`) and only warns if that input is
  turned off. Running this strategy on a true netting account without
  hedging support will merge same-direction trades and the averaging math
  will not behave as designed.
- **Equity drawdown baseline is session-lifetime**, captured once at
  `OnInit()`. It does not reset on terminal restart unless the EA is
  removed and re-added (which re-captures the baseline). This is a
  deliberate conservative choice — resetting the baseline on every restart
  would let repeated restarts silently raise the effective drawdown
  ceiling.
- **Trend/ATR filters only gate new cycles**, never an already-open basket,
  by design (per spec §28/§51). They will not prevent a basket already in
  drawdown from continuing to average if volatility rises mid-basket.
- **`MinimumMarginLevelPercent` check on `CanStartNewCycle()`** uses
  `InitialLot`/`ORDER_TYPE_BUY` as a representative pre-check before the
  breakout direction is known; the real per-trade check
  (`PassRiskChecksForAveraging` / `IsMarginSafe`) is always re-evaluated
  with the correct direction and lot before every actual order.
- **No compiler was available in this development environment** — the code
  was written and reviewed for MQL5 syntax/API correctness by hand, but it
  has not been compiled in MetaEditor. Compile and run it there before any
  live or demo deployment; do not deploy on a funded account without first
  validating in Strategy Tester and on a demo account.

## 14. Example trade scenarios

**BUY example** (defaults, XAUUSD @ 3500.00):
`BUY STOP=3500.50`, `SELL STOP=3499.50`. Price rises and BUY STOP fills at
(actual) 3500.51. `SELL STOP` is cancelled immediately. Price then falls:
next averaging trigger is `3500.51 - 0.50 = 3500.01` → BUY 0.02 lots;
continuing down, BUY 0.03 at ~3499.51, BUY 0.05 at ~3499.01, BUY 0.08 at
~3498.51. After each fill the weighted average and TP (`average + 0.50`)
are recalculated from the live positions. When Bid reaches the TP and net
profit ≥ `MinimumBasketProfit`, all four positions are closed together in
one pass of `ProcessBasketClosing()`, then a 5-second cooldown, then a new
cycle at the new market price.

**SELL example**: symmetric — `SELL STOP` fills, `BUY STOP` is cancelled,
each further averaging level opens `GridStep` *above* the last actual SELL
fill, and the basket TP is `average - BasketTPDistance`.

**Both-sides emergency example**: a sudden 2-point spike gaps through both
the BUY STOP and SELL STOP before the EA's cancel-opposite logic can act.
`ReconcileBasketState()` sees positions on both sides on the very next tick,
switches to `STATE_EMERGENCY_BOTH_SIDES`, cancels any remaining pending
orders, and (with the default `BothSidesEmergencyMode=0`) closes both
baskets and enters cooldown rather than ever averaging into either side.
