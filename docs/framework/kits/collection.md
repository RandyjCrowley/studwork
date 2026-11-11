# Collection kit: Items, Rarity, Inventory

Items, weighted rolls with luck, pity and mutations, and owned item copies. Code:
`packages/kits/collection`. Phase 1 status: being rebuilt on the module API (agent A). Every entry
marked **(contract)** is pinned by
[PHASE1-CONTRACT.md]((internal build report, not public)) and offered today through
the compat bridge; names and meanings don't change when the real module lands.

```lua
local Collection = ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Collection")
local Items = require(Collection:WaitForChild("Items"))
local Rarity = require(Collection:WaitForChild("Rarity"))       -- needs Items
local Inventory = require(Collection:WaitForChild("Inventory")) -- needs Items
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
  `getOddsDetail(tableId, player?) -> OddsDetail?`, `tiers()` (the resolved ordered tier list,
  contract), `setLuck(player, luck, tableId?)`, `getLuck(player, tableId?)`. `RollInfo = { ok,
  reason?, mutation?, pity, instance? }`; reasons: `unknown_table`, `restricted`, `not_loaded`,
  `inventory_full`, `empty_table`.
- **purchaseOps (contract):** `roll(tx, tableId, luck?) -> (def?, info)`: a paid roll inside a
  purchase, through `compliance.roll`; the item is granted with a `paid:` source.
- **txApi (contract):** `roll(tx, tableId, luck?) -> (def?, info)`: a free roll inside your tx.
- **Client action:** `roll(tableId)` (tables with a `cost` and `paid ~= true`): capacity is checked
  before spending, a coin-priced roll spends and rolls in one transaction.
- **Replicated `extra`:** `odds = { [tableId] = OddsDetail }` for every table with a `cost`,
  `paid = true` or `luckDisclosed = true`. Render it with `UI.OddsTable`; never compute odds on the
  client.
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
  its slot this way).
- **Mail kind:** owns `"core_gift"`, registered with `Mail.registerKind` when Mail is enabled.
- **Signals (contract):** `ItemAdded(player, instance)`, `ItemRemoved(player, instance)`.
- **Client action:** `gift(toUserId, uid)` (same server: instant transfer).
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
