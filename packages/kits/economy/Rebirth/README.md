# Rebirth (economy kit)

Layout (v1.3.1, one folder per module, module-api.md §1): `module.luau` (definition), `server/` (server part; the code files named below live there), `client/` (client part). Rojo: `ReplicatedStorage.Modules.Rebirth` (module, client, shared), `ServerScriptService.Modules.Rebirth` (server).

A real StudWork module (v1.3.0). Definition: `module.luau`. Pure math:
`RebirthMath.luau`; the inventory rules: `Rebirth.keeps` (`RebirthRules.spec.luau`).

## Config (`config.Rebirth`)
- `rebirth = { baseCost, costGrowth, currency?, multiplierPerRebirth, keepInventory, keepDisplayed?,
  resetCurrencies? (default { primary }), maxRebirths? }`; defaults 5000 / 3 / 0.5 / false / false
  (the template's values). cost = `floor(baseCost * costGrowth ^ rebirths)`, multiplier =
  `1 + rebirths * multiplierPerRebirth`.
- `onRebirth` (the inventory rules, below).

## Save data
Section `rebirth` = `{ rebirths }` (replicated).

## API
`canRebirth`, `rebirth(player) -> boolean`, `cost`, `multiplier`, `signals.Rebirthed(player, n)`.
Client action `rebirth()`: wire event `Rebirth` (no data) in this module's `net.blink` (RemoteScope
`STUDWORK_REBIRTH`), limit 0.5/s burst 2 (v1.3.1; was the framework event `RequestRebirth`).
`extensions.resetStep(id, fn(tx, player))`: runs inside the rebirth transaction, in registration
order, before `rebirths` is incremented. Each step writes its own section (`ctx.section(tx)`).
Upgrades and Plot reset themselves this way.

## The rebirth transaction
One `ctx.tx`: re-check max + balance; pay the cost (`Economy.txApi.spend`, only when the cost
currency isn't reset anyway); reset `resetCurrencies` to `Economy.startingBalance(id)`; unless
`keepInventory`, remove the wiped copies with `Inventory.txApi.remove(tx, uid, "rebirth")`
(optional Inventory; each fires Inventory's `onItemRemoved` hooks and `ItemRemoved`); run the
reset steps; `rebirths += 1`. After commit: `Rebirthed`, the Economy rate refresh, a `toast`,
`analytics.custom("Rebirth")`. `CurrencyChanged` (reason `"rebirth"`) comes from Economy.

## Inventory rules (`config.Rebirth.onRebirth`)
Defaults are the v1.2 rules. Collection derives a copy's source tag and Rebirth never rewrites it,
so the trade/policy rules that read the tag apply to whatever is kept.

| key | default | allowed | meaning |
|---|---|---|---|
| `paid` | `"keep"` | `"keep"` only | Robux copies (`paid:`) are always kept. Any other value fails boot; `ItemDef.keepOnRebirth = false` doesn't wipe them either. |
| `paidCurrency` | `"wipe"` | `"wipe"`, `"keep"` | copies rolled with a paid currency (`paidcur:`). `"keep"` keeps the tag: still a paid random item (odds shown, untradeable for restricted players). Wiping is the default so spending earned Coins right before a rebirth can't make items rebirth-proof. |
| `earned` | `"wipe"` | `"wipe"`, `"keep"` | every other copy |
| `itemOverrides` | `true` | boolean | `ItemDef.keepOnRebirth` true keeps / false wipes a non-Robux copy |

`rebirth.keepInventory = true` keeps everything. Unknown item ids are kept and warned about.
