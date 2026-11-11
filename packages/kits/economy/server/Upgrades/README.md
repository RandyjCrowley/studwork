# Upgrades (economy kit)

A real StudWork module (core-v1.3.0 Phase 1). Definition: `../../shared/Upgrades.luau`. Pure math:
`UpgradeMath.luau` (+ spec).

## Config (`config.Upgrades`)
`upgrades = { [id]: { baseCost, costGrowth, currency? (default Economy's primary), maxLevel,
effect = "incomeMultiplier" | "inventoryCap" | "custom", perLevel, resetsOnRebirth? } }`, default `{}`.

## Save data
Section `upgrades` = `{ upgrades = { [id]: level } }` (replicated).

## API
`level(player, id)`, `cost(player, id) -> number?` (`floor(baseCost * costGrowth ^ level)`, nil when
maxed/unknown), `purchase(player, id) -> (ok, reason?)` (`unknown_upgrade`, `not_loaded`, `maxed`,
`cannot_afford`), `signals.UpgradePurchased(player, id, level)`. Client action `upgrade`
(`RequestUpgrade`).

## Behaviour
- `purchase` is one transaction: the level is re-read, the cost is paid with `Economy.txApi.spend`
  and the level is bumped, so both commit or neither does. A paid currency is accepted here (a
  non-random sink; kit-private `KitAccess` token): every shipped game prices upgrades in Coins,
  which are also Robux-buyable.
- `incomeMultiplier` upgrades are an Economy `rateFactor` (`1 + level * perLevel` each);
  `inventoryCap` is read by Inventory through `level`; `custom` is read by the game.
- With Rebirth enabled, a `resetStep` resets every level whose `resetsOnRebirth ~= false`.
