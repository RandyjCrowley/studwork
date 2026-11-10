# Core.Inventory

Owned item copies in `PlayerData.inventory` (`Types.InventoryAPI`).
Pure rules in `InventoryRules.luau` (tests: `InventoryRules.spec.luau`); pure gifting steps in
`Gift.luau` (tests incl. the never-duplicated/never-lost property test: `Gift.spec.luau`).

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

## sendGift (v1.2, needs the Mail module)

`sendGift(from, toUserId, uid, reason?) -> (ok, reason?)` gifts an owned copy to ANY user (offline,
another server, a stranger). Checks in order (`InventoryRules.giftCheck`): `mail_off`,
`not_loaded`, `bad_target` (not a positive integer), `same_player`, `not_owned`,
`restricted_source` (source `paid:`/`paidcur:`: the receiver's paid-random policy is unknown while
they may be offline, so fail closed). Then `Plot.clearDisplay` (re-checked after), then ONE
`Data.update(from)`: `inventory[uid]` removed + `Mail.sendInto(tx, toUserId, "core_gift",
{ item = { uid, itemId, mutation, meta, source, acquiredAt }, from, reason }, "g-<GUID>")` (key made
once inside the update). If `sendInto` refuses, the update is discarded (`failed`). `ItemRemoved`
and `Analytics.custom("GiftSent")` after commit. The message leaves only after the update is
saved (Mail outbox), so the item is never duplicated or lost across crashes.

Receiver (`core_gift`, registered in `start` when Mail is on; `Gift.receiveInto`):
unknown itemId -> error (Mail retries / dead-letters); uid already owned -> success (idempotent);
inventory full -> `false` (the gift waits in the receiver's mailbox until `Mail.claim`); else the
SAME instance (uid/mutation/meta/source kept, `acquiredAt` = now) in one update, then `ItemAdded`
and a toast.

RequestGift (client): `toUserId` positive integer, not self; `uid` an id the sender owns;
per-sender `GIFT_COOLDOWN_SEC` (2 s) after a successful gift, on top of Net's rate limit. Receiver
in this server -> `transfer` (instant, v1.1 rules); otherwise `sendGift` when Mail is on.

Gotcha: as a fallback, `remove`/`transfer` also drop dangling `displayed` references to the uid inside
the same `Data.update` (no `ItemUndisplayed` fires for that path; Plot's own clearDisplay normally ran first).
