# Plot (base kit, core-v1.3.0 module)

Layout (core-v1.3.1, one folder per module, module-api.md §1): `module.luau` (definition), `server/` (server part; the code files named below live there), `client/` (client part). Rojo: `ReplicatedStorage.Modules.Plot` (module, client, shared), `ServerScriptService.Modules.Plot` (server).

Assigns each player a plot, shows their displayed items on it, frees it when they leave.
Definition `module.luau` (depends on Inventory; optional Items, Rarity, Rebirth).
api: `get`, `owner`, `display`, `clearDisplay`, `slots`, `onAssigned`, `displayed(player)` (frozen
slotId -> uid). signals: `ItemDisplayed`, `ItemUndisplayed`, `DisplayCleared(player, slotId)`,
`PlotAssigned`, `PlotReleased`. Replicated extra `plotName`.

Config (`config.Plot`): `plot.slotCount`, `plot.autoDisplay`, `plot.keepDisplayedOnRebirth`
(default false; replaces `balance.rebirth.keepDisplayed`), `assetsFolderName` (default
`GameAssets`), `plotTag` (default `CorePlot`).

Cross-module writes are gone: an item leaving the inventory clears its slot through
`Inventory.extensions.onItemRemoved` (inside the removing tx), a rebirth clears `displayed` through
`Rebirth.extensions.resetStep`. Tier colours come from the optional Rarity module's `tiers()`.
Files:

- `init.luau`: the service (Roblox glue)
- `Slots.luau`: pure selection logic (slot order, slotCount, tag filter, validation, stale-entry
  cleanup, auto-display plan, plot order) + `Slots.spec.luau`

## Game-facing contract (attributes / names)

| Where | Name | Type | Meaning |
|---|---|---|---|
| plot Model | tag `config.Plot.plotTag` (default `CorePlot`) | CollectionService tag | this Model is a plot. Added/removed at runtime is fine. |
| plot Model | `PlotOrder` | number (optional) | assignment order: plots with it first (ascending), then the rest by natural `Name` order (`Plot2` < `Plot10`) |
| plot Model | `OwnerUserId` | number | **written by core** while owned. Don't set it yourself; if you do, core treats the plot as taken. |
| BasePart in plot | `SlotId` | string | a display slot. Ids must be unique within a plot; the same id on every plot keeps a player's layout when they get a different plot. |
| slot BasePart | `SlotTag` | string (optional) | slot only accepts items whose `ItemDef.tags` contain this tag (e.g. `"Shelf"`). No tag = accepts any item. |
| BasePart in plot | named `Spawn`, or attribute `PlotSpawn = true` | | optional: the owner's character is moved there on assignment and every respawn (server `PivotTo`, 3 studs above the part). |
| ReplicatedStorage | `GameConfig.assetsFolderName` (default `GameAssets`) | Folder | item models looked up by `ItemDef.model` (Model or BasePart). Scripts in the clone are removed. |

Slot order is natural order of `SlotId` (`slot2` < `slot10`); `balance.plot.slotCount` (if set) keeps
the first N slots of that order. Slots beyond it are ignored.

Display visuals live in a `CoreDisplays` Folder inside the plot, named `Display_<slotId>`, with
attributes `ItemUid`, `ItemId`, `Rarity`, `DisplaySlotId`. All parts are anchored, with
`CanCollide`/`CanQuery`/`CanTouch` = false.

## Behaviour

- **Assignment**: on `Data.onLoaded` the player gets the first free plot (order above). Core sets
  `OwnerUserId`, replicates `plotName` (`ctx.setReplicated`), fires `PlotAssigned`, then the
  `onAssigned` handlers. No free plot: one warning per player, player queued (FIFO), assigned
  when a plot is released or a new `CorePlot` appears. If an owned plot is untagged or destroyed,
  the owner's session is released and they're queued for another plot.
- **Release** (leave / plot removed): one Trove per session (visual folder, CharacterAdded
  connection, attribute reset) is destroyed, `plotName` cleared, `PlotReleased` fired.
- **Source of truth** is `PlayerData.displayed` (slotId -> uid). Visuals are re-rendered from it
  on assignment, `DataLoaded`, `Rebirthed` and every display change. On those "re-read
  everything" points, entries are removed (with `ItemUndisplayed`) when the uid isn't owned any more,
  the uid is shown twice, or the slot isn't an active slot of the current plot.
- **display(player, uid, slotId?)** -> `(true)` or `(false, reason)`. Reasons: `no_plot`,
  `not_owned`, `already_displayed`, `no_slot`, `slot_taken`, `tag_mismatch`, `no_free_slot`.
  No `slotId` = first compatible free slot. Writes through `Data.update`, fires `ItemDisplayed`.
- **clearDisplay(player, uid)** -> boolean. Fires `ItemUndisplayed`.
- **autoDisplay** (`balance.plot.autoDisplay`): `ItemAdded` items, and items owned before the plot
  was assigned (starter items, oldest first), go to the first compatible free slot.
  `ItemRemoved` always clears the item's slot.
- **owner(plot)**: the Player who owns the plot, or nil. Use it in touch/prompt handlers:
  `if Core.Plot.owner(plotModel) ~= player then return end`.
- **Actions** (core-v1.3.1, Plot's own `net.blink`, `RemoteScope = "STUDWORK_PLOT"`):
  `display(uid, slotId?)` (event `Display`, `(Id, Id?)`) and `clearDisplay(uid)` (event
  `ClearDisplay`, `Id`), each 8/s burst 16, replacing the framework's `RequestDisplay` /
  `RequestClearDisplay`. Client: `StudWork.use(Plot).actions.display(uid)`. The handlers check that
  the strings are 1..64 chars and that the uid is in the sender's inventory, and always act on the
  sender's own plot (the wire has no plot argument). Tests: `h:action(p, Plot, "display", uid)`.
- **Visuals**: a clone of the item model, or a 2-stud placeholder Part in the rarity colour (Neon
  from glowStrength 0.5 up); a PointLight in the tier glow colour (brightness scales with
  `glowStrength`, none for Common); a BillboardGui with the item name in the tier colour
  (`StudsOffsetWorldSpace`, MaxDistance 80). Highlight isn't used because of the ~31 per client
  limit. Idle bob/spin isn't done on the server; a client effect can find visuals through
  `CoreDisplays`.
- **Console** (Studio only): `plot show [userId]` prints the assignment and slot occupancy.

## Performance
- The slot map (slotId -> part + sorted records) is cached per session (`SlotCache.luau`), built once at assignment by walking the plot **without** the `CoreDisplays` folder. It is invalidated only when a BasePart with a `SlotId` is added to / removed from the plot outside `CoreDisplays`. Editing `SlotId`/`SlotTag` on an already-parented part does not invalidate: set slot attributes before parenting.
- `display` runs the cheap checks first (`Slots.precheck`: `data.inventory[uid]`, already displayed) before any slot lookup. `clearDisplay` never looks up slots (and deliberately does not require ownership: it runs on `ItemRemoved`, after the item left the inventory).

## Ownership of `displayed`
- Plot is the only writer of `PlayerData.displayed`; every Plot `Data.update` writes only that section.
- Rebirth reset step `addResetStep("Plot", ...)` -> `Slots.resetDisplayed(data, balance.rebirth.keepDisplayed)`: clears every slot, or with `keepDisplayed` keeps owned items and drops uids that left the inventory.
- `ItemRemoved` -> `clearDisplay` (Inventory no longer scrubs `displayed`).
- `Items` is optional: without it (`ctx.isEnabled("Items")` false) items are treated as untagged and labelled with their itemId.

