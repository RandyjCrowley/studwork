# Economy (economy kit)

Layout (core-v1.3.1, one folder per module, module-api.md §1): `module.luau` (definition), `server/` (server part; the code files named below live there), `client/` (client part). Rojo: `ReplicatedStorage.Modules.Economy` (module, client, shared), `ServerScriptService.Modules.Economy` (server).

A real StudWork module (core-v1.3.0 Phase 1). Definition: `module.luau`. Server part:
`init.luau` (`Economy.new()`, one per runtime). Pure math: `RateMath.luau` (+ spec).

## Config (`config.Economy`, defaults)
| key | default | meaning |
|---|---|---|
| `primaryCurrency` | `"Coins"` | HUD / default currency |
| `currencies` | none | further currencies Economy owns; Economy registers the paid-currency spender only for `primaryCurrency` + these (R20) |
| `startingCurrency` | none | `{ [currency]: amount }` granted on the first join |
| `income.tickSeconds` | `1` | seconds between payouts (shared ticker) |
| `income.source` | `"owned"` | `"owned"` = every inventory copy earns; `"displayed"` = only plot copies |
| `multiplierStacking` | `"multiply"` | `"add"` = `1 + Σ(f-1)` |

Robux-buyable currencies are framework config: `GameConfig.compliance.paidCurrencies`.

## Save data
Section `economy` = `{ currency = { [id]: number }, multipliers = { [id]: { mult, expiresAt? } } }`
(the v1.2 fields; `FrameworkSection.V12_MAP` splits a v1.2 save into it). Replicated:
`data.currency`, `data.multipliers`, `extra.ratePerSec`, `extra.multiplier`.

## Item fields
`item.economy.incomePerSec` and `mutation.economy.incomeMultiplier` (default 1). An item without an
`economy` table earns nothing, so a collection-only game (cards, cosmetics, quest items) is valid
with or without Economy.

## API
- `grant / spend(player, amount, reason, currency?) -> boolean`, `balance(player, currency?)`.
  Amount finite and > 0, reason a string, the player loaded; known currency = the primary, a
  `startingCurrency` key or one the player holds. **`spend` of a paid currency errors**
  ("spend a paid currency only through compliance.spendForRoll", §14 C3).
- `addIncomeSource / removeIncomeSource`, `addMultiplier(player, id, mult, expiresAt?, persist?)`
  (saved when `persist` or `expiresAt`), `removeMultiplier`, `getMultiplier`, `getRate`.
- Additions: `primaryCurrency()`, `startingBalance(currency)`.
- `signals.CurrencyChanged(player, currency, newBalance, delta, reason)` (reason `"income"` for ticks).
- `txApi`: `grant(tx, ...)`, `spend(tx, ...)` (same refusal), `balance(tx, currency?)` (addition).
- `purchaseOps.grant(tx, amount, currency?)`, reason `"product:<product>"`.
- Compliance: Economy registers the spender of every paid currency, so `compliance.spendForRoll`
  spends it inside the roll's tx (reason `"roll"`).

## Extensions
- `rateFactor(id, fn(player) -> number | {number}) -> invalidate(player)`: a multiplier factor read
  on recompute (Rebirth, Upgrades). Call `invalidate(player)` when its inputs change.
- `displayedSource(fn(player) -> { [slotId]: uid }) -> invalidate(player)`: the displayed set for
  `income.source = "displayed"`. Plot registers it (Plot declares `optional = { Economy }`), so
  Economy never requires Plot's definition (no require cycle with Plot -> Rebirth -> Economy).
  On this branch the compat adapter registers it for the bridged Plot.

## Income rules (v1.2, RateMath)
`rate = (Σ item income + Σ income sources) × combine(factors, multiplierStacking)`; item income =
`incomePerSec × incomeMultiplier` over `Inventory.list` ("owned") or the displayed set's
`Inventory.get` ("displayed"). Item defs come from `ctx.gameConfig.items` (the frozen catalog
`Items.get` serves); the mutation multiplier from `Items.mutation(id)` (optional Items).
Factors: every `rateFactor`, active saved boosts, session boosts. Computed from save data only, so
it is valid in any load handler (Offline relies on it).

## Performance
Per-player cached rate with a dirty flag (Inventory `ItemAdded`/`ItemRemoved`, the extension
invalidators, source/multiplier changes, the earliest boost expiry). One `onTick` per
`tickSeconds`: O(players), one section write each. Income is logged to analytics every 60 s of
ticks per player and on leave.

## Console (Studio)
`economy grant <amount> [currency] [userId]`, `economy rate [userId]`.
