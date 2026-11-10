# Core.Economy

Currency (grant/spend/balance), item income, extra income sources and stacking multipliers.
Public API: `Types.EconomyAPI`. Pure math: `RateMath.luau` (+ `RateMath.spec.luau`).

## Config keys
`balance.primaryCurrency`, `balance.startingCurrency`, `balance.income.tickSeconds`,
`balance.income.source` (`"displayed"` | `"owned"`), `balance.multiplierStacking`
(`"multiply"` default, `"add"` = `1 + Σ(f-1)`), `balance.upgrades[*]` (incomeMultiplier effect),
`balance.rebirth.multiplierPerRebirth` (through `Rebirth.multiplier`).

## Behaviour
- `grant/spend(player, amount, reason, currency?)`: amount must be finite and > 0, reason a
  string, the player loaded. Known currency = the primary, any key in `balance.startingCurrency`,
  or a key the player already holds in `PlayerData.currency`. Spend checks and deducts inside one
  `Data.update` (never negative). Fires `CurrencyChanged(player, id, newBalance, delta, reason)`.
- Item income comes from PlayerData (displayed or owned) via `Items.incomeOf`. Nobody else calls
  `addIncomeSource` for items; it is for game-defined extra sources (session only).
- `getMultiplier` = stack of `Rebirth.multiplier`, `1 + level*perLevel` per incomeMultiplier
  upgrade (read from saved levels), saved boosts (`PlayerData.multipliers`) and session boosts.
  `addMultiplier(.., expiresAt?, persist?)` saves the entry when `persist == true` or
  `expiresAt ~= nil`; otherwise it is session-only (co-play). Expired entries are ignored and
  pruned (on load and on the tick they expire).
- Replicates `ratePerSec` and `multiplier` via `ctx.setReplicated` only when they change.

## Performance
Per-player cached `rate`/`mult` with a dirty flag. Invalidated by `ItemAdded`, `ItemRemoved`,
`ItemDisplayed`, `ItemUndisplayed`, `Rebirthed`, `UpgradePurchased`, `DataLoaded`/`onLoaded`,
add/removeIncomeSource, add/removeMultiplier, and the earliest boost `expiresAt` (stored per
player, compared each tick). One loop per `tickSeconds` walks loaded players:
**O(P) per tick** (one comparison + one `Data.update` + one `CurrencyChanged` per player).
A recompute is O(items + upgrades + boosts) and only happens on invalidation. 50 players x 100
items => 50 cheap updates per tick; a 100-item recompute only when that player's items change.
Tick is wrapped in `debug.profilebegin("Core.Economy.tick")`. dt is measured (capped at 2 ticks).

## Analytics
grant/spend log `Analytics.economy(player, Source|Sink, currency, amount, kind, sku)` where the
reason `"kind:sku"` is split (e.g. `upgrade:IncomeBoost`). Income ticks (and grants with reason
`"income"`) are summed and flushed every 60 s per player and on leave (transaction `income`).

## Signals
Fires `CurrencyChanged` (reason `"income"` for ticks). Listens to the item/rebirth/upgrade/data
signals above.

## Console (Studio)
`grant <amount> [currency] [userId]`, `rate [userId]`.

## Gotchas
- The rate is computed from PlayerData only (not Plot instances), so it is valid inside any
  `Data.onLoaded` handler (Offline relies on this).
- Session boosts added before data loads are kept in memory only.
