# Inventory (collection kit)

Layout (core-v1.3.1, one folder per module, module-api.md §1): `module.luau` (definition), `server/` (server part; the code files named below live there), `client/` (client part). Rojo: `ReplicatedStorage.Modules.Inventory` (module, client, shared), `ServerScriptService.Modules.Inventory` (server).

Real StudWork module (core-v1.3.0). Definition: `module.luau` (config, save
section, migration, sanitize); server part: `server/init.luau` (full API in its header). Pure rules in
`InventoryRules.luau`, pure gifting steps in `Gift.luau` (incl. the never-duplicated/never-lost
property test in `Gift.spec.luau`). Integration tests: `../tests/Collection.spec.luau`.

- Save section `inventory = { inventory = { [uid]: ItemInstance } }` (the v1.2 field, unchanged).
- `api`: `add, remove, get, list, count, cap, transfer, canTrade, sendGift` + `signals.ItemAdded /
  ItemRemoved`. `get`/`list` return FROZEN views in every environment, cached by section version.
- `txApi`: `add, remove, list, count` (inside the caller's tx). `purchaseOps.addItem`.
- `extensions.onItemRemoved(fn(tx, player, instance))` fires inside the removing tx (remove,
  transfer, sendGift); a hook error discards the removal. Inventory never touches Plot.
  `extensions.capBonus(id, fn(player) -> number)` adds to `cap`.
- Source tags: `paid:<product>` / `paidcur:<source>` are derived from the tx; a caller's
  `paid:`-prefixed `source` outside such a tx is refused.
- Gifts: `core_gift` via `ctx.depsExt[Mail].registerKind` (optional Mail); no `paid:`/`paidcur:`
  copies by mail; `transfer` refuses paid copies when either player is restricted.
- `config.Inventory = { inventory = { cap = 50 }, starterItems = {} }` (defaults).

## Actions and wire

| Action | Wire (`net.blink`, RemoteScope `STUDWORK_INVENTORY`) | Limit |
|---|---|---|
| `gift(toUserId, uid)` | event `Gift`, `Data: (f64, Id)` (generated `server/Net.luau`, `client/Net.luau`) | 1/s, burst 3 |

Client: `StudWork.use(Inventory).actions.gift(toUserId, uid)`. Tests: `h:action(p, Inventory, "gift", ...)`.
core-v1.3.1 (R19): replaces the framework Blink event `RequestGift`.
