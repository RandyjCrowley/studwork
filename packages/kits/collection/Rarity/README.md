# Rarity (collection kit)

Layout (v1.3.1, one folder per module, module-api.md §1): `module.luau` (definition), `server/` (server part; the code files named below live there), `client/` (client part), `shared/` (both sides). Rojo: `ReplicatedStorage.Modules.Rarity` (module, client, shared), `ServerScriptService.Modules.Rarity` (server).

Real StudWork module (v1.3.0). Definition: `module.luau`; server part:
`init.luau` (full API in its header). Pure math: `RollMath.luau` (tests seeded with
`SeededRng.luau`), `LuckRule`, `LuckRegistry`, `OddsSync`. Tiers: `shared/Tiers.luau`.

- `config.Rarity.tiers`: `"standard7"` (default) or an ordered list `{ { id, color?, glow?,
  glowStrength?, soundKey? } }`. Items' `rarity` must be a tier of it (boot error). Luck
  (`luckMinTier`, default the 3rd tier: "Rare" in standard7) and pity (`minTier`) compare by list
  order. The definition contributes `theme.rarity.tiers` = standard7; with a custom list, set
  `GameConfig.theme.rarity.tiers` to the same list (a boot warning says so). The resolved list is
  also replicated as `extra.tiers`.
- Every rarity table is a Compliance random source; every outcome comes from
  `ctx.compliance.roll` / `spendForRoll` (the `sample` is the weighted pick + pity + mutation +
  grant). No `opts.free`.
- `api`: `roll(tableId, player, luck?, { grant?, reason? })`, `getOdds`, `getOddsDetail`, `tiers`,
  `setLuck`, `getLuck`. `txApi.roll(tx, tableId, luck?, opts?)`, `purchaseOps.roll(tx, tableId,
  luck?)` (grants, `paid:<product>`).
- Hard rule 11 (luck on a paid roll needs `luckDisclosed` and the client shown that luck):
  Compliance for purchases / `spendForRoll`, LuckRule here for a `paid = true` table outside a
  purchase. The `roll` action checks capacity and the rule before anything is spent.
- v1.6.0: `getOddsDetail(tableId, player?, luck?)`: a pure preview at exactly that (sanitized)
  luck. Per-item luck: `discloseItem(player, tableId, itemKey, luck) -> boolean` /
  `clearItem(player, tableId, itemKey)` (through `ctx.compliance.discloseItem`; every table
  registers `oddsAt`), and `opts.item` on `roll` / `txApi.roll` / `purchaseOps.roll`. An item roll
  uses exactly its luck (never session luck). Free: any luck. Paid: policy gate, then the item's
  odds must have been sent at exactly the roll's luck (`odds_not_disclosed` otherwise), luck != 1
  needs `luckDisclosed`. Cap: `Compliance.MAX_ITEM_DISCLOSURES` (64) per player, refuse, never
  evict. Client: `read.itemOdds(state, tableId?, itemKey?)`. Example (an egg in an incubator):
  `Rarity.discloseItem(player, "NestEgg", egg.id, egg.luck)` when the egg arrives, then in the
  hatch product `tx.use(Rarity).roll("NestEgg", egg.luck, { item = egg.id })`, then `clearItem`.
  Details: `docs/framework/kits/collection.md`.
- Save section `rarity = { pity = { [tableId]: count } }` (the v1.2 field, unchanged; server-only).
- Replicated `extra.odds` for tables with a cost, `paid` or `luckDisclosed` (luck-adjusted per
  player while their luck ~= 1 on a luckDisclosed table).

## Actions and wire

| Action | Wire (`net.blink`, RemoteScope `STUDWORK_RARITY`) | Limit |
|---|---|---|
| `roll(tableId)` | event `Roll`, `Data: Id` (generated `server/Net.luau`, `client/Net.luau`) | 4/s, burst 8 |

Client: `StudWork.use(Rarity).actions.roll(tableId)`. Tests: `h:action(p, Rarity, "roll", ...)`.
v1.3.1 (R19): replaces the framework Blink event `RequestRoll`.
