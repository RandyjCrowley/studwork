# Core.Rarity

Weighted rolls with luck, pity and mutations (`Types.RarityAPI`). Owner: agent C (v1.2 luck: agent B).
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

## Luck: setLuck(player, luck, tableId?) / getLuck(player, tableId?) (v1.2, N4)

Session-only registry (`LuckRegistry.luau`): per player, for one table or every table (`tableId`
nil); a per-table value wins over the all-table one, even a per-table 1. Values go through
`RollMath.sanitizeLuck`. Cleared on PlayerRemoving. `roll`/`rollInto` with `luck == nil` use
`getLuck(player, tableId)`, so Shop's `tx.roll(tableId)` inherits it. `setLuck` re-sends that
player's odds.

## Hard rule 11: luck on paid rolls

A roll is *paid* when `opts.paid == true` or the table has `paid = true` (RequestRoll passes
`paid = true` for a cost in `balance.paidCurrencies`; Shop's `tx.roll` always does). A paid roll
whose effective luck is not 1 **errors** in `rollInto` (message names table, luck and reason)
unless the table has `luckDisclosed = true` AND `ctx.sentReplicated(player, "odds")[tableId]`
has `luckDisclosed = true` and exactly that `luck`. The decision is the pure `LuckRule.check`
(order: free -> ok, luck 1 -> ok, `luck_not_disclosed`, `odds_not_sent`, `sent_luck_mismatch`).
Inside a Robux handler the error means NotProcessedYet, so nobody is charged. RequestRoll checks
the rule BEFORE spending and only toasts "Odds are updating, try again in a moment" (no spend, no
error). Free rolls may use any luck. Passing an explicit `luck` that differs from `getLuck` to a
paid roll always fails the rule (the client was sent `getLuck`'s odds): use `setLuck`.

## getOddsDetail(tableId, player?) -> Types.OddsDetail?

With `player` and a `luckDisclosed` table the probabilities include `getLuck(player, tableId)`
and `detail.luck` says which; otherwise `luck = 1`. `detail.luckDisclosed` mirrors the table.

Full disclosure (pure `RollMath.oddsDetail`): `items` (base odds), `mutationChance`,
`mutations` (each = chance * weight share; default weight 1, non-positive weights never rolled),
`outcomes` (every item x (no mutation | mutation) with its final probability on a normal roll,
sums to 1) and `pity = { threshold, minTier, items }` (forced-roll odds) when the table's pity
rule is valid and has an entry >= minTier. `paid` = `paid = true` or priced in a
`balance.paidCurrencies` currency. Rolls go through the same `RollMath.step`
(`OddsDetail.spec.luau` checks 200k seeded rolls against `outcomes` within 4 standard errors).

### Showing odds in a game (required for paid random items)

At start Rarity replicates `ReplicatedState.odds[tableId]` for every table with a `cost`,
`paid = true` or `luckDisclosed = true`. Every player's `state.odds` equals the odds their own
rolls use (`OddsSync.luau`): the shared luck-free map goes out once with `setReplicatedAll`; a
player gets a per-player override (shared map + their luck-adjusted details) only while their
luck differs from 1 on a luckDisclosed table, cleared back to the shared map (nil) afterwards.
**N3:** every `Items.register` after start (`Items.onRegistered`) rebuilds and re-sends the shared
map and every override; the start-time warning for unknown items stays. Render it with the UI
kit, never with odds computed on the client:

```lua
e(UI.OddsTable, { detail = Core.Client.state().odds.Egg, items = Config.items })
```
For a luckDisclosed table with luck ~= 1 the detail is luck-adjusted and `UI.OddsTable` shows
"Includes your luck x1.5" above the items.

## RequestRoll (client)

Only tables with a currency `cost` and `paid ~= true`. Capacity is checked before spending (no spend
when full); then `Economy.spend`, then roll+grant; if the roll still fails the cost is refunded with
`Economy.grant(player, amount, "refund:<tableId>", currency)`.

## Paid-random compliance checklist

- [ ] The table has `paid = true` and is only rolled from a `Shop.onProduct` handler.
- [ ] Handler passes `{ paid = true, grant = true }`; returns `false` (not granted) when `info.ok` is false
      so the purchase is not consumed (or grant a non-random alternative).
- [ ] The odds UI renders `ReplicatedState.odds[tableId]` (`UI.OddsTable` `detail`) before the prompt.
- [ ] Restricted players (`ReplicatedState.paidRandomRestricted`) don't see the purchase prompt; offer
      an earnable or direct-purchase alternative.
- [ ] Items from paid rolls keep `source = "paid:<tableId>"` (trades are then blocked for restricted
      players by Inventory).

## Studio console

`roll <tableId> [userId]` (grants), `odds <tableId> [luck|userId]` (a number above `MAX_LUCK` is
a userId: shows that player's disclosed, luck-adjusted detail), `luck <userId> <luck> [tableId]`.
