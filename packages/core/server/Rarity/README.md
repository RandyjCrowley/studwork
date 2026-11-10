# Core.Rarity

Weighted rolls with luck, pity and mutations (`Types.RarityAPI`). Owner: agent C.
Pure math lives in `RollMath.luau` (tests: `RollMath.spec.luau`, seeded with `SeededRng.luau`).

## roll(tableId, player, luck?, opts?) -> (ItemDef?, RollInfo)

Failure reasons, in check order: `unknown_table`, `restricted` (`opts.paid` and
`Policy.paidRandomRestricted`), `not_loaded`, `inventory_full` (with `opts.grant`, checked before rolling
so pity isn't spent), `empty_table`.

- **Luck**: non-finite / `<= 0` -> 1, clamped to `RollMath.MAX_LUCK` (100). Multiplies the weight of
  entries whose tier >= `table.luckMinTier` (default `"Rare"`). Example Collector's skill meter feeds this.
- **Pity** (`table.pity = { threshold, minTier }`): `PlayerData.pity[tableId]` counts consecutive rolls
  below `minTier`. When the count is `>= threshold - 1`, the roll is restricted to entries `>= minTier`,
  so the `threshold`-th roll is guaranteed. A `>= minTier` result resets to 0, anything else adds 1.
  Saved with `Data.update` after a successful roll. `RollInfo.pity = true` when the restriction applied.
  A table with no entry `>= minTier` never forces.
- **Mutation**: with `table.mutationChance` (0..1) pick one of `balance.mutations`, weighted by
  `Mutation.weight` (default 1). Returned in `RollInfo.mutation` and applied to the granted copy.
- `opts.grant`: `Inventory.add` with source `"paid:<tableId>"` when `opts.paid`, else `opts.reason or
  "roll"`; sends `ctx.net.feedback(player, "item", def.name, def.rarity)`; `RollInfo.instance` is set.
  If you roll `paid` without `grant`, grant it yourself with source `"paid:<tableId>"`.

## getOdds(tableId, luck?) -> { [itemId]: probability }

Exact probabilities of the non-pity roll with that luck; they sum to 1 and use the same weights as
`roll`. Unknown items / bad weights are dropped from both. `tiers()` returns `RarityTiers.all()`.

### Showing odds in a game (required for paid random items)

```lua
-- server: send the odds to the client however your game does UI (e.g. a game remote / attribute)
local odds = Core.Rarity.getOdds("Egg")
for itemId, p in odds do
    local def = Core.Items.get(itemId)
    print(def.name, def.rarity, string.format("%.2f%%", p * 100))
end
```
Show every item with its percentage *before* the purchase prompt, and keep it in sync with config.

## RequestRoll (client)

Only tables with a currency `cost` and `paid ~= true`. Capacity is checked before spending (no spend
when full); then `Economy.spend`, then roll+grant; if the roll still fails the cost is refunded with
`Economy.grant(player, amount, "refund:<tableId>", currency)`.

## Paid-random compliance checklist

- [ ] The table has `paid = true` and is only rolled from a `Shop.onProduct` handler.
- [ ] Handler passes `{ paid = true, grant = true }`; returns `false` (not granted) when `info.ok` is false
      so the purchase is not consumed (or grant a non-random alternative).
- [ ] The odds UI uses `getOdds(tableId)` and is shown before the prompt.
- [ ] Restricted players (`ReplicatedState.paidRandomRestricted`) don't see the purchase prompt; offer
      an earnable or direct-purchase alternative.
- [ ] Items from paid rolls keep `source = "paid:<tableId>"` (trades are then blocked for restricted
      players by Inventory).

## Studio console

`roll <tableId> [userId]` (grants), `odds <tableId> [luck]`.
