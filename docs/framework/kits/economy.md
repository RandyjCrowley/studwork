# Economy kit: Economy, Upgrades, Rebirth, Offline

Currencies, item income and multipliers, level upgrades, rebirth, and offline earnings. Code:
`packages/kits/economy`. Phase 1 status: being rebuilt on the module API (agent B). Entries marked
**(contract)** are pinned by
[PHASE1-CONTRACT.md]((internal build report, not public)) and offered today through
the compat bridge.

```lua
local EconomyKit = ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Economy")
local Economy = require(EconomyKit:WaitForChild("Economy"))
local Upgrades = require(EconomyKit:WaitForChild("Upgrades")) -- needs Economy
local Rebirth = require(EconomyKit:WaitForChild("Rebirth"))   -- needs Economy
local Offline = require(EconomyKit:WaitForChild("Offline"))
```

Switch the whole kit off and Collection still works: items without an `economy` field earn
nothing (cards, cosmetics, quest items).

## Economy

**Config (`config.Economy`):**

| Key | Default | Meaning |
|---|---|---|
| `primaryCurrency` | `"Coins"` | the HUD's currency and the default for every currency argument |
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
  `removeMultiplier(player, id)`, `getMultiplier(player)`, `getRate(player)`. Amounts are finite
  and > 0; `spend` never goes negative.
- **txApi (contract):** `grant(tx, amount, reason, currency?) -> boolean`, `spend(tx, amount,
  reason, currency?) -> boolean` (same paid-currency refusal).
- **purchaseOps (contract):** `grant(tx, amount, currency?) -> boolean`.
- **Compliance:** registers the currency spender for every paid currency.
- **Signals (contract):** `CurrencyChanged(player, currency, newBalance, delta, reason)`; income
  ticks use reason `"income"`.
- **Replicated:** `data.currency`; `extra.ratePerSec`, `extra.multiplier` (sent when they change).
- **Save data:** section `economy`: `{ currency = { [id] = number }, multipliers = { [id] = {
  mult, expiresAt? } } }` (saved boosts; session boosts are memory only).

## Upgrades

**Config (`config.Upgrades`):** `upgrades = { [id] = { name, baseCost, costGrowth, currency?,
maxLevel, effect, perLevel, resetsOnRebirth? } }`. `cost(level) = floor(baseCost * costGrowth ^
level)`; `currency` defaults to the primary; `resetsOnRebirth` defaults to `true`. Effects:
`incomeMultiplier` (Economy applies `1 + level * perLevel`), `inventoryCap` (Inventory adds
`level * perLevel` slots), `custom` (your code reads `level`).

- **API:** `level(player, id)`, `cost(player, id) -> number?` (nil at max), `purchase(player, id)
  -> (ok, reason?)` (`unknown_upgrade`, `not_loaded`, `maxed`, `cannot_afford`).
- **Signals (contract):** `UpgradePurchased(player, upgradeId, level)`.
- **Client action:** `upgrade(upgradeId)`.
- **Replicated `data`:** `upgrades`. **Save data:** section `upgrades`: `{ upgrades = { [id] = level } }`.

## Rebirth

**Config (`config.Rebirth`):** `rebirth = { baseCost, costGrowth, currency?, multiplierPerRebirth,
keepInventory, keepDisplayed?, resetCurrencies?, maxRebirths? }` (required when Rebirth is
listed). `cost = floor(baseCost * costGrowth ^ rebirths)`; multiplier = `1 + rebirths *
multiplierPerRebirth`; `resetCurrencies` defaults to `{ primary }`.

The inventory rule is a documented default: with `keepInventory = false`, a copy is kept when its
item has `keepOnRebirth = true`, or when `keepOnRebirth` is nil and the copy was bought with Robux
(`paid:`); copies from coin rolls (`paidcur:`) and everything else are wiped. It is applied through
`ctx.depsTx[Inventory]` (optional Inventory), contract.

- **API:** `canRebirth(player)`, `rebirth(player) -> boolean`, `cost(player)`, `multiplier(player)`.
- **Extensions (contract):** `resetStep(id, fn(tx, player))`: runs inside Rebirth's single
  transaction; write your own section with `ctx.section(tx)` (Upgrades and Plot reset this way).
- **Signals (contract):** `Rebirthed(player, count)`.
- **Client action:** `rebirth()`.
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
