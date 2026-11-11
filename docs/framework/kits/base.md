# Base kit: Plot

Per-player plots with item display slots. Code: `packages/kits/base/<Module>/` (one folder per module: `module.luau`, `server/`, `client/`; Rojo `ReplicatedStorage.Modules.<Module>`, `ServerScriptService.Modules.<Module>`). Entries marked
**(contract)** are part of the cross-module surface listed in [kit-contract.md](../kit-contract.md).

```lua
local Plot = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Plot"):WaitForChild("module")) -- needs Inventory
```

## Config (`config.Plot`)

| Key | Default | Meaning |
|---|---|---|
| `plot.slotCount` | all slots | keep the first N slots (natural `SlotId` order) |
| `plot.autoDisplay` | `false` | new items (and items owned before the plot was assigned) go to the first compatible free slot |
| `plot.keepDisplayedOnRebirth` | `false` | keep owned items on display through a rebirth |
| `assetsFolderName` | `"GameAssets"` | child of ReplicatedStorage holding item models (`ItemDef.model`) |
| `plotTag` | `"CorePlot"` | CollectionService tag that marks a plot Model |

The plot model and the tags and attributes Plot reads:

| Where | Name | Meaning |
|---|---|---|
| plot Model | tag `CorePlot` (`plotTag`) | this Model is a plot (added/removed at runtime is fine) |
| plot Model | attribute `PlotOrder` (number, optional) | assignment order; then natural `Name` order |
| plot Model | attribute `OwnerUserId` | written by the framework while owned; don't set it |
| BasePart in plot | attribute `SlotId` (string) | a display slot; same ids on every plot keep a player's layout |
| slot BasePart | attribute `SlotTag` (string, optional) | only items whose `tags` contain it |
| BasePart in plot | named `Spawn`, or `PlotSpawn = true` | the owner spawns there |

## API

`get(player) -> Model?`, `owner(plot) -> Player?` (use it in touch/prompt handlers), `display(player,
uid, slotId?) -> (ok, reason?)` (`no_plot`, `not_owned`, `already_displayed`, `no_slot`,
`slot_taken`, `tag_mismatch`, `no_free_slot`), `clearDisplay(player, uid) -> boolean`,
`slots(player) -> { string }`, `onAssigned(fn(player, plot)) -> Connection`, and
**`displayed(player) -> { [slotId] = uid }`** (new, frozen, contract).

## Hooks it uses (optional dependencies)

- `Inventory.onItemRemoved` (contract): when an item leaves the inventory, Plot clears its slot in
  the same transaction, writing only its own section.
- `Rebirth.resetStep` (contract): clears the slots, or with `config.Plot.plot.keepDisplayedOnRebirth`
  keeps owned items.
- `Economy.displayedSource` (contract): supplies the displayed set for `income.source = "displayed"`.

## Signals (contract)

`ItemDisplayed(player, uid, slotId)`, `ItemUndisplayed(player, uid, slotId)`,
`DisplayCleared(player, slotId)`, `PlotAssigned(player, plot)`, `PlotReleased(player, plot)`.

## Client actions

`StudWork.use(Plot).actions.display(uid, slotId?)`, `.clearDisplay(uid)`: they act on the sender's
own plot only and check the uid is in the sender's inventory. Since v1.3.1 they are
module actions (module-api.md §9) on Plot's own `net.blink` (`RemoteScope = "STUDWORK_PLOT"`):

| Action | Blink event | Wire types | Limit (per player) |
|---|---|---|---|
| `display` | `Display` | `(Id, Id?)` (`Id = string(1..64)`) | 8/s, burst 16 |
| `clearDisplay` | `ClearDisplay` | `Id` | 8/s, burst 16 |

They replace the framework events `RequestDisplay` / `RequestClearDisplay` (same wire types, same
limits). The handler re-checks argument types (also when called with `h:action` in tests) and
returns `display`'s `(ok, reason?)` / `clearDisplay`'s boolean.

## Replicated

`data.displayed`; `extra.plotName` (contract).

## Save data

Section `plot`: `{ displayed = { [slotId] = uid } }`. Plot is its only writer.
