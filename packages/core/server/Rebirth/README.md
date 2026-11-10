# Core.Rebirth

Public API: `Types.RebirthAPI`. Pure math: `RebirthMath.luau` (+ spec).

## Config: `balance.rebirth`
`baseCost`, `costGrowth` (cost = floor(baseCost * costGrowth ^ rebirths)), `currency` (default
primary), `multiplierPerRebirth` (multiplier = 1 + rebirths * per), `keepInventory`,
`keepDisplayed`, `resetCurrencies` (default `{ primary }`), `maxRebirths`.
Also reads `balance.startingCurrency` (reset value) and `balance.upgrades[*].resetsOnRebirth`.

## Behaviour
`rebirth(player)` does ONE `Data.update` that re-checks max/balance, pays the cost (only when the
cost currency is not reset anyway), resets `resetCurrencies` to their starting value (or 0),
runs the registered reset steps (Upgrades resets its levels, Plot drops displayed slots whose uid
left the inventory), and with `keepInventory = false` filters the inventory with
`RebirthMath.keptInventory`: a copy is kept when `ItemDef.keepOnRebirth == true`, or when it is
nil and `instance.source` starts with `"paid:"` (bought with Robux); wiped when
`keepOnRebirth == false` or not paid. Unknown item ids are kept (and warned). Without the Items
module everything is kept. Increments `rebirths`. Rebirth itself writes only `currency`,
`inventory` and `rebirths`. Then fires
`CurrencyChanged` (reason `rebirth`) for changed currencies, `Rebirthed(player, n)` (listeners
re-read everything; no per-item ItemRemoved, per the pinned contract), a `toast` feedback and
analytics (`economy Sink rebirth`, `custom "Rebirth"`).
`RequestRebirth` remote -> `rebirth(player)` (no client args).
