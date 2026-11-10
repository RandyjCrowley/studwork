# Core.Upgrades

Public API: `Types.UpgradesAPI`. Pure math: `UpgradeMath.luau` (+ spec).

## Config: `balance.upgrades[id]`
`baseCost`, `costGrowth` (cost(level) = floor(baseCost * costGrowth ^ level)), `currency`
(default primary), `maxLevel` (cost = nil at max), `effect`, `perLevel`, `resetsOnRebirth`.

## Effects
- `incomeMultiplier`: Economy reads the saved level: factor `1 + level * perLevel`.
- `inventoryCap`: Inventory computes `cap + Σ level * perLevel` (`UpgradeMath.capBonus` mirrors it).
- `custom`: level only; the game reads `Upgrades.level`.

## Behaviour
`purchase` validates the id (`Validate.isId` + must exist in config), refuses when not loaded or
maxed, spends via `Economy.spend` (atomic check+deduct, analytics Sink `upgrade:<id>`), then bumps
the level in the same frame and fires `UpgradePurchased(player, id, level)`. Returns
`(false, "unknown_upgrade" | "not_loaded" | "maxed" | "cannot_afford")` on failure.
`RequestUpgrade(upgradeId)` remote -> `purchase` after id validation.
Rebirth resets levels with `resetsOnRebirth ~= false` (`UpgradeMath.afterRebirth`).
