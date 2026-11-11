# Collection kit: Items, Rarity, Inventory

Items, weighted rolls with luck, pity and mutations, and owned item copies. Code:
`packages/kits/collection/<Module>/` (one folder per module: `module.luau`, `server/`, `client/`; Rojo `ReplicatedStorage.Modules.<Module>`, `ServerScriptService.Modules.<Module>`). Entries
marked **(contract)** are part of the cross-module surface listed in
[kit-contract.md](../kit-contract.md).

```lua
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Items = require(Modules:WaitForChild("Items"):WaitForChild("module"))
local Rarity = require(Modules:WaitForChild("Rarity"):WaitForChild("module"))       -- needs Items
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module")) -- needs Items
```

## Items

The item registry over `GameConfig.items` (base fields: `id`, `name`, `rarity`, `model`, `icon`,
`tags`, `source`, `keepOnRebirth`, plus the namespaced fields of enabled modules). Items are
declared once in `GameConfig.items` and validated at boot; there is no `register`.

- **Config:** none of its own. Mutations are `config.Rarity.mutations`.
- **API (contract):** `get(id) -> ItemDef?` (frozen, with namespaced fields), `all() -> { ItemDef }`,
  `byTag(tag) -> { ItemDef }`, `mutation(id) -> MutationDef?`, `mutations() -> { MutationDef }`.
- **Removed in v1.3:** `Items.incomeOf` (Economy computes income from
  `item.economy.incomePerSec x mutation.economy.incomeMultiplier`), `register`, `onRegistered`.
- **Save data:** none.

## Rarity

Weighted rolls with luck, pity and mutations; odds disclosure through Compliance.

**Config (`config.Rarity`):**

| Key | Default | Meaning |
|---|---|---|
| `tiers` **(contract)** | `"standard7"` | a preset name or an ordered list `{ { id, color?, glow?, soundKey? } }`; item `rarity` strings are checked against it. `standard7` = Common, Uncommon, Rare, Epic, Legendary, Mythic, Secret |
| `rarityTables` | none | `{ [tableId] = RarityTable }` (below) |
| `mutations` | `{}` | `{ { id, name, color?, weight? (default 1), economy = { incomeMultiplier }? } }` (v1.2: `multiplier`) |

A rarity table:

| Field | Default | Meaning |
|---|---|---|
| `entries` | required | `{ { itemId, weight > 0 } }` |
| `cost` | nil (server-only table) | `{ currency, amount }`: players may roll it with the client action `roll`; needs Economy and Inventory |
| `paid` | `false` | bought with Robux: paid random item rules apply |
| `luckMinTier` | `"Rare"` | luck multiplies the weights of tiers >= this |
| `luckDisclosed` | `false` | odds are disclosed per player including their luck; only such a table may take a paid roll with luck != 1 |
| `pity` | none | `{ threshold, minTier }`: the `threshold`-th roll in a row below `minTier` is forced to >= `minTier` |
| `mutationChance` | `0` | 0..1 chance the result gets a mutation |

- **API:** `roll(tableId, player, luck?, opts?) -> (ItemDef?, RollInfo)`, `getOdds(tableId, luck?)`,
  `getOddsDetail(tableId, player?, luck?) -> OddsDetail?`, `discloseItem(player, tableId, itemKey,
  luck) -> boolean`, `clearItem(player, tableId, itemKey)`, `tiers()` (the resolved ordered tier list,
  contract), `setLuck(player, luck, tableId?)`, `getLuck(player, tableId?)`. `RollInfo = { ok,
  reason?, mutation?, pity, instance? }`; reasons: `unknown_table`, `restricted`, `not_loaded`,
  `inventory_full`, `empty_table`, `policy_unknown`, `odds_not_disclosed`.
- **purchaseOps (contract):** `roll(tx, tableId, luck?, opts?) -> (def?, info)`: a paid roll inside a
  purchase, through `compliance.roll`; the item is granted with a `paid:` source. `opts.item` (v1.6.0).
- **txApi (contract):** `roll(tx, tableId, luck?, opts?) -> (def?, info)`: a free roll inside your
  tx (`opts = { grant?, reason?, item? }`).
- **Client action:** `roll(tableId)` (tables with a `cost` and `paid ~= true`): capacity is checked
  before spending, a coin-priced roll spends and rolls in one transaction. Wire: Rarity's own
  `net.blink` event `Roll` (`Data: Id`, RemoteScope `STUDWORK_RARITY`), rate limit 4/s, burst 8.
  Client: `StudWork.use(Rarity).actions.roll(tableId)`; tests: `h:action(p, Rarity, "roll", tableId)`.
- **Replicated `extra`:** `odds = { [tableId] = OddsDetail }` for every table with a `cost`,
  `paid = true` or `luckDisclosed = true`; `tiers` (the resolved tier list). Render it with `UI.OddsTable`; never compute odds on the
  client.
- **Odds preview at any luck (v1.6.0):** `getOddsDetail(tableId, player, luck)` returns the odds
  at exactly that luck (sanitized: `<= 0` / non-finite -> 1, above 100 -> 100). It is pure: it
  doesn't change the player's luck, disclose anything or touch replication. For "odds at 0 / 50 /
  100%" boards. Without `luck` nothing changed.
- **Luck on a single item (v1.6.0):** a roll can carry its own luck for one item (an egg in an
  incubator) with `opts.item = itemKey` (a short id, <= 64 chars). An item roll uses exactly the
  `luck` it is given (nil = 1), never the player's session luck, and never changes `getLuck`.
  - **Free** item rolls may use any luck; the key is only a label.
  - **Paid** item rolls (inside a purchase, through `spendForRoll` / after `spendPaid`, or a
    `paid = true` table) pass the usual gate (unknown policy -> retry / `policy_unknown`;
    restricted -> `restricted`), then need `discloseItem(player, tableId, itemKey, luck)` to have
    reached the player's client **at exactly the roll's luck** (else `odds_not_disclosed`; a
    purchase retries later), and luck != 1 needs `luckDisclosed = true` (hard rule 11 error).
    Both sides go through `RollMath.sanitizeLuck`, so a disclosed luck always matches its roll.
  - At most `Compliance.MAX_ITEM_DISCLOSURES` (64) item disclosures per player across tables:
    past that `discloseItem` returns `false` (nothing is evicted; `clearItem` hatched eggs first).
    They are dropped when the player leaves.
  - The client reads them from the framework field `itemOdds = { [tableId] = { [itemKey] =
    OddsDetail } }`: `StudWork.use(Rarity).read.itemOdds(state, tableId, itemKey)` gives the detail
    to pass to `UI.OddsTable` (`detail` prop).

  ```lua
  -- egg delivered with a skill score: show its odds in the incubator
  Rarity.discloseItem(player, "NestEgg", egg.id, egg.luck)
  -- the player buys "hatch now" (a dev product): roll that egg at its own luck
  ctx.shop.onProduct("HatchNow", function(tx)
  	local egg = currentEgg(tx.player)
  	local def, info = tx.use(Rarity).roll("NestEgg", egg.luck, { item = egg.id })
  	assert(def and info.ok, info.reason) -- odds_not_disclosed: the purchase retries later
  	tx.after(function()
  		Rarity.clearItem(tx.player, "NestEgg", egg.id)
  	end)
  end)
  ```
- **Theme (contract):** contributes `theme.rarity = { tiers = <resolved list> }`.
- **Save data:** section `rarity`: `{ pity = { [tableId] = count } }`, not replicated.

## Inventory

Owned item copies, capacity, transfers and gifts.

**Config (`config.Inventory`):**

| Key | Default | Meaning |
|---|---|---|
| `inventory.cap` | required (integer >= 1) | slots per player, plus Upgrades with `effect = "inventoryCap"` |
| `starterItems` | `{}` | item ids granted on the first join |

- **API:** `add(player, itemId, opts?) -> ItemInstance?`, `remove(player, uid, reason?) -> ItemInstance?`,
  `get(player, uid) -> ItemInstance?`, `list(player)` (frozen views, contract), `count(player)`, `cap(player)`,
  `transfer(from, to, uid, reason) -> (ok, reason?)`, `canTrade(player)`,
  `sendGift(from, toUserId, uid, reason?) -> (ok, reason?)` (needs Mail; works across servers and
  for offline players). `opts = { mutation?, source?, meta?, reason? }`.
- **txApi (contract):** `add(tx, itemId, opts?) -> ItemInstance?`, `remove(tx, uid, reason) ->
  boolean`, `list(tx)` (frozen views of the tx working copy), `count(tx)`.
- **purchaseOps (contract):** `addItem(tx, itemId, opts?) -> ItemInstance?`; the `paid:` source tag
  is derived from the transaction, your `source` becomes the reason suffix.
- **Extensions (contract):** `onItemRemoved(fn(tx, player, instance))`: runs inside the removing
  transaction; `ctx.section(tx)` in the hook is the registering module's own section (Plot clears
  its slot this way). `capBonus(id, fn(player) -> number)`: adds slots to `cap(player)` (Upgrades'
  `inventoryCap` effect).
- **Mail kind:** owns `"core_gift"`, registered with `Mail.registerKind` when Mail is enabled.
- **Signals (contract):** `ItemAdded(player, instance)`, `ItemRemoved(player, instance)`.
- **Client action:** `gift(toUserId, uid)` (same server: instant transfer). Wire: Inventory's own
  `net.blink` event `Gift` (`Data: (f64, Id)`, RemoteScope `STUDWORK_INVENTORY`), rate limit 1/s,
  burst 3, plus the per-sender gift cooldown. Client: `StudWork.use(Inventory).actions.gift(toUserId, uid)`;
  tests: `h:action(p, Inventory, "gift", toUserId, uid)`.
- **Replicated `data`:** `inventory`.
- **Save data:** section `inventory`: `{ inventory = { [uid] = ItemInstance } }` where
  `ItemInstance = { uid, itemId, mutation?, acquiredAt, source?, meta? }`. A `source` starting with
  `paid:` was bought with Robux (kept on rebirth by default, untradeable for paid-random-restricted
  players); `paidcur:` came from a roll priced in a paid currency.

## Example

```lua
-- your module, declaring dependsOn = { Inventory }
ctx.tx(player, function(tx)
	local copy = ctx.depsTx[Inventory].add(tx, "pebble", { source = "quest" })
	if copy then
		ctx.section(tx).rewarded = true
	end
end)
```
