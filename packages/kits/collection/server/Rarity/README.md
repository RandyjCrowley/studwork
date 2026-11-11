# Rarity (collection kit)

Real StudWork module (core-v1.3.0). Definition: `../../shared/Rarity.luau`; server part:
`init.luau` (full API in its header). Pure math: `RollMath.luau` (tests seeded with
`SeededRng.luau`), `LuckRule`, `LuckRegistry`, `OddsSync`. Tiers: `../../shared/Tiers.luau`.

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
  purchase. RequestRoll checks capacity and the rule before anything is spent.
- Save section `rarity = { pity = { [tableId]: count } }` (the v1.2 field, unchanged; server-only).
- Replicated `extra.odds` for tables with a cost, `paid` or `luckDisclosed` (luck-adjusted per
  player while their luck ~= 1 on a luckDisclosed table).
