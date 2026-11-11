# Upgrades (economy kit)

Layout (v1.3.1, one folder per module, module-api.md §1): `module.luau` (definition), `server/` (server part; the code files named below live there), `client/` (client part). Rojo: `ReplicatedStorage.Modules.Upgrades` (module, client, shared), `ServerScriptService.Modules.Upgrades` (server).

A real StudWork module (v1.3.0). Definition: `module.luau`. Pure math:
`UpgradeMath.luau` (+ spec).

## Config (`config.Upgrades`)
`upgrades = { [id]: { baseCost, costGrowth, currency? (default Economy's primary), maxLevel,
effect = "incomeMultiplier" | "inventoryCap" | "custom", perLevel, resetsOnRebirth? } }`, default `{}`.

## Save data
Section `upgrades` = `{ upgrades = { [id]: level } }` (replicated).

## API
`level(player, id)`, `cost(player, id) -> number?` (`floor(baseCost * costGrowth ^ level)`, nil when
maxed/unknown), `purchase(player, id) -> (ok, reason?)` (`unknown_upgrade`, `not_loaded`, `maxed`,
`cannot_afford`), `signals.UpgradePurchased(player, id, level)`. Client action `upgrade(id)`: wire event `Upgrade`
(`Data: Id` = `string(1..64)`) in this module's `net.blink` (RemoteScope `STUDWORK_UPGRADES`), limit
6/s burst 12; unknown ids are dropped (v1.3.1; was the framework event `RequestUpgrade`).

## Behaviour
- `purchase` is one transaction: the level is re-read, the cost is paid with `Economy.txApi.spend`
  and the level is bumped, so both commit or neither does. A paid currency is paid through the
  public `ctx.compliance.spendPaid` (a non-random good; any module can do the same): every shipped
  game prices upgrades in Coins, which are also Robux-buyable.
- `incomeMultiplier` upgrades are an Economy `rateFactor` (`1 + level * perLevel` each);
  `inventoryCap` is read by Inventory through `level`; `custom` is read by the game.
- With Rebirth enabled, a `resetStep` resets every level whose `resetsOnRebirth ~= false`.
