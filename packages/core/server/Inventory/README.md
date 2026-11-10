# Core.Inventory

Owned item copies in `PlayerData.inventory` (`Types.InventoryAPI`). Owner: agent C.
Pure rules in `InventoryRules.luau` (tests: `InventoryRules.spec.luau`).

- `add(player, itemId, opts?)`: nil when the item is unknown, data not loaded, inventory at cap,
  `opts.mutation` not in `balance.mutations`, `opts.source` not a short string (<= 64), or `meta` too
  big (<= 8 keys, keys <= 32 chars, values string<=64 / finite number / boolean, <= 256 bytes total).
- `remove(player, uid, reason?)`: clears it from the plot first (`Plot.clearDisplay`).
- `get`, `list`, `count`.
- `cap(player) = balance.inventory.cap + Σ Upgrades.level(id) * perLevel` over upgrades with
  `effect == "inventoryCap"`.
- `canTrade(player)`: in this server and data loaded.
- `transfer(from, to, uid, reason) -> (ok, reason?)`: `not_loaded`, `same_player`, `not_owned`,
  `restricted` (either side paid-random restricted and the item source starts with `paid:`),
  `inventory_full`, `failed` (receiver write failed; item rolled back). `Plot.clearDisplay(from, uid)`
  runs first, then the same uid moves with no yield between sender removal and receiver add.
- Starter items (`balance.starterItems`) on first join (`stats.sessions == 1`, empty inventory).

Signals: `ItemAdded` / `ItemRemoved` on every change (transfer = removed on sender + added on receiver).

RequestGift (client): `toUserId` positive integer, in this server, not self; `uid` an id the sender
owns; per-sender `GIFT_COOLDOWN_SEC` (2 s) after a successful gift, on top of Net's rate limit.

Gotcha: as a fallback, `remove`/`transfer` also drop dangling `displayed` references to the uid inside
the same `Data.update` (no `ItemUndisplayed` fires for that path; Plot's own clearDisplay normally ran first).
