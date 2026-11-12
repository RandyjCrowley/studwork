# Economy kit: Economy, Upgrades, Rebirth, Offline

Currencies, item income and multipliers, level upgrades, rebirth, and offline earnings. Code:
`packages/kits/economy/<Module>/` (one folder per module: `module.luau`, `server/`, `client/`; Rojo `ReplicatedStorage.Modules.<Module>`, `ServerScriptService.Modules.<Module>`). Entries marked
**(contract)** are part of the cross-module surface listed in [kit-contract.md](../kit-contract.md).

```lua
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))
local Upgrades = require(Modules:WaitForChild("Upgrades"):WaitForChild("module")) -- needs Economy
local Rebirth = require(Modules:WaitForChild("Rebirth"):WaitForChild("module"))   -- needs Economy
local Offline = require(Modules:WaitForChild("Offline"):WaitForChild("module"))
```

Switch the whole kit off and Collection still works: items without an `economy` field earn
nothing (cards, cosmetics, quest items).

## Economy

**Config (`config.Economy`):**

| Key | Default | Meaning |
|---|---|---|
| `primaryCurrency` | `"Coins"` | the HUD's currency and the default for every currency argument |
| `currencies` | none | further currencies Economy owns besides `primaryCurrency`. Economy is the compliance spender (`ctx.compliance.registerCurrencySpender`) only for paid currencies it owns, so list a non-primary currency here if it is in `compliance.paidCurrencies` (boot fails if a paid currency has no spender). Each listed currency is known like the primary: every player has it (0 unless `startingCurrency` says otherwise) and grant/spend accept it (v1.6.0) |
| `startingCurrency` | `{}` | `{ [currency] = amount }` for a new player; its keys are known currencies |
| `income.tickSeconds` | required (> 0) | payout interval; 1 = every second |
| `income.source` | required | `"displayed"` (items shown on the plot; needs Plot) or `"owned"` (everything owned) |
| `multiplierStacking` | `"multiply"` | `"add"` = `1 + sum(f - 1)` |

Paid currencies are framework config: `GameConfig.compliance.paidCurrencies = { "Gems" }`.

- **Item fields:** `item.economy.incomePerSec` (number), `mutation.economy.incomeMultiplier`.
- **API:** `grant(player, amount, reason, currency?) -> boolean`, `spend(player, amount, reason,
  currency?) -> boolean` (errors for a paid currency: spend those only through
  `compliance.spendForRoll`, contract), `balance(player, currency?)`, `addIncomeSource(player, id,
  perSec)`, `removeIncomeSource(player, id)`, `addMultiplier(player, id, mult, expiresAt?, persist?)`,
  `removeMultiplier(player, id)`, `getMultiplier(player)`, `getRate(player)`, `primaryCurrency()`,
  `startingBalance(currency)`. Amounts are finite and > 0; `spend` never goes negative.
- **txApi (contract):** `grant(tx, amount, reason, currency?) -> boolean`, `spend(tx, amount,
  reason, currency?) -> boolean` (same paid-currency refusal), `balance(tx, currency?)`.
- **Extensions (contract):** `rateFactor(id, fn(player) -> number | { number }) -> invalidate(player)`
  (a factor in the income rate; Rebirth and Upgrades use it), `displayedSource(fn(player) -> {
  [slotId] = uid }) -> invalidate(player)` (the displayed set for `income.source = "displayed"`;
  Plot provides it).
- **purchaseOps (contract):** `grant(tx, amount, currency?) -> boolean`.
- **Compliance:** registers the currency spender for every paid currency.
- **Signals (contract):** `CurrencyChanged(player, currency, newBalance, delta, reason)`; income
  ticks use reason `"income"`.
- **Replicated:** `data.currency`, `data.multipliers`; `extra.ratePerSec`, `extra.multiplier` (sent when they change).
- **Save data:** section `economy`: `{ currency = { [id] = number }, multipliers = { [id] = {
  mult, expiresAt? } } }` (saved boosts; session boosts are memory only).

**Client part (`Economy/client/`):** the HUD currency widget `"Economy.currency"`
(topCenter, order 1: `config.Economy.primaryCurrency` + its rate unless `HudOptions.showRate ==
false`), registered with `UI.registerWidget` at start (it used to be built into the framework HUD;
same id, so `client.hud.widgets["Economy.currency"]` overrides work unchanged). Client actions:
`StudWork.use(Upgrades).actions.upgrade(id)`, `StudWork.use(Rebirth).actions.rebirth()` (from
`Upgrades/client/`, `Rebirth/client/`). Each fires its module's own Blink event
(`Upgrades/net.blink` `Upgrade(Id)`, limit 6/s burst 12; `Rebirth/net.blink` `Rebirth`, limit 0.5/s
burst 2). Before v1.3.1 these were framework events (`RequestUpgrade` / `RequestRebirth`).

## Upgrades

**Config (`config.Upgrades`):** `upgrades = { [id] = { name, baseCost, costGrowth, currency?,
maxLevel, effect, perLevel, resetsOnRebirth? } }`. `cost(level) = floor(baseCost * costGrowth ^
level)`; `currency` defaults to the primary; `resetsOnRebirth` defaults to `true`. Effects:
`incomeMultiplier` (Economy applies `1 + level * perLevel`), `inventoryCap` (Inventory adds
`level * perLevel` slots), `custom` (your code reads `level`).

- **API:** `level(player, id)`, `cost(player, id) -> number?` (nil at max), `purchase(player, id)
  -> (ok, reason?)` (`unknown_upgrade`, `not_loaded`, `maxed`, `cannot_afford`).
- **Signals (contract):** `UpgradePurchased(player, upgradeId, level)`.
- **Client action:** `upgrade(upgradeId)` (wire: `Upgrades/net.blink` event `Upgrade`, limit 6/s burst 12).
- **Replicated `data`:** `upgrades`. **Save data:** section `upgrades`: `{ upgrades = { [id] = level } }`.

## Rebirth

**Config (`config.Rebirth`):** `rebirth = { baseCost, costGrowth, currency?, multiplierPerRebirth,
keepInventory, keepDisplayed?, resetCurrencies?, maxRebirths? }` (required when Rebirth is
listed). `cost = floor(baseCost * costGrowth ^ rebirths)`; multiplier = `1 + rebirths *
multiplierPerRebirth`; `resetCurrencies` defaults to `{ primary }`.

The inventory rule is a documented default: Robux-bought copies (`paid:`) are always kept (no config
and no `keepOnRebirth = false` can wipe them); copies from coin rolls (`paidcur:`) and everything else
are wiped unless the item has `keepOnRebirth = true` (or `config.Rebirth.onRebirth.paidCurrency` /
`onRebirth.earned` is `"keep"`; `onRebirth.itemOverrides = false` ignores the item flags). It is
applied through
`ctx.depsTx[Inventory]` (optional Inventory), contract.

- **API:** `canRebirth(player)`, `rebirth(player) -> boolean`, `cost(player)`, `multiplier(player)`.
- **Extensions (contract):** `resetStep(id, fn(tx, player))`: runs inside Rebirth's single
  transaction; write your own section with `ctx.section(tx)` (Upgrades and Plot reset this way).
- **Signals (contract):** `Rebirthed(player, count)`.
- **Client action:** `rebirth()` (wire: `Rebirth/net.blink` event `Rebirth`, limit 0.5/s burst 2).
- **Replicated `data`:** `rebirths`. **Save data:** section `rebirth`: `{ rebirths = 0 }`.

## Offline

**Config (`config.Offline`):** `offline = { capSeconds, minSeconds, payoutFraction (0..1),
autoPay }` (required when Offline is listed; `autoPay` needs Economy).

On load (not the first session): seconds away = `clamp(now - lastSeen, 0, capSeconds)`; below
`minSeconds` nothing happens; with `autoPay` it pays `floor(rate * secondsAway * payoutFraction)`
(reason `offline`).

- **API:** `onReturn(fn(player, secondsAway)) -> Connection` (contract). Uses `ctx.framework.lastSeen`.
- **Save data:** none.

## Example

```lua
-- a quest module, dependsOn = { Economy }
ctx.tx(player, function(tx)
	if ctx.depsTx[Economy].grant(tx, ctx.config.reward, "quest:daily") then
		ctx.section(tx).claimedDay = today
	end
end)
```
