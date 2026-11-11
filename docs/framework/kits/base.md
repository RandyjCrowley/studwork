# Base kit: Plot

Per-player plots with item display slots. Code: `packages/kits/base/<Module>/` (one folder per module since core-v1.3.1: `module.luau`, `server/`, `client/`; Rojo `ReplicatedStorage.Modules.<Module>`, `ServerScriptService.Modules.<Module>`). Phase 1 status: being
rebuilt on the module API (agent C). Entries marked **(contract)** are pinned by
[PHASE1-CONTRACT.md]((internal build report, not public)).

```lua
local Plot = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Plot"):WaitForChild("module")) -- needs Inventory
```

## Config (`config.Plot`)

| Key | Default | Meaning |
|---|---|---|
| `plot.slotCount` | all slots | keep the first N slots (natural `SlotId` order) |
| `plot.autoDisplay` | `false` | new items (and items owned before the plot was assigned) go to the first compatible free slot |
| `assetsFolderName` | `"GameAssets"` | child of ReplicatedStorage holding item models (`ItemDef.model`) |

The plot model and tag set (agent C makes the tag configurable in Phase 1; the default stays):

| Where | Name | Meaning |
|---|---|---|
| plot Model | tag `CorePlot` | this Model is a plot (added/removed at runtime is fine) |
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
- `Rebirth.resetStep` (contract): clears the slots, or with `config.Rebirth.rebirth.keepDisplayed`
  keeps owned items.

## Signals (contract)

`ItemDisplayed(player, uid, slotId)`, `DisplayCleared(player, slotId)`.

## Client actions

`display(uid, slotId?)`, `clearDisplay(uid)`: they act on the sender's own plot only and check
the uid is in the sender's inventory.

## Replicated

`data.displayed`; `extra.plotName` (contract).

## Save data

Section `plot`: `{ displayed = { [slotId] = uid } }`. Plot is its only writer.
