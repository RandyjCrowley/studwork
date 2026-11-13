# Companions kit

Equip owned item copies and show them following their owner. Add `Items`, `Inventory` and
`Companions` to `GameConfig.modules`; `Rarity`, `Economy`, `Rebirth` and `Plot` are optional.
Code lives in `packages/kits/companions/Companions/`.
After adding the module or its project mappings, run `tools/sync-projects` before linting.

## Quick start

```lua
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Items = require(Modules:WaitForChild("Items"):WaitForChild("module"))
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local Companions = require(Modules:WaitForChild("Companions"):WaitForChild("module"))

-- GameConfig:
modules = { Items, Inventory, Companions },
items = {
    { id = "pebble", name = "Pebble", model = "Pebble", companions = { movement = "hop" } },
},
config = { Companions = { slots = 3, autoEquipBest = false } },
```

Put the `Pebble` Model or BasePart in `ReplicatedStorage.GameAssets`. A missing model uses a
primitive placeholder. Models need no Humanoid. This server example is mirrored by
`Companions/test/QuickStart.spec.luau`:

```lua
local copy = StudWork.use(Inventory).add(player, "pebble")
assert(copy)
local companions = StudWork.use(Companions)
assert(companions.equip(player, copy.uid))
assert(companions.equipped(player)[1].uid == copy.uid)
```

Open the default screen on the client with `StudWork.use(Companions).open()`.
Inside your own server module, declare dependencies and use `ctx.deps[Companions]` and
`ctx.deps[Inventory]` instead of the facade.

## Item fields

An item with `companions = {}` is eligible. Items without this namespace cannot be equipped.
Base `model`, `icon` and `rarity` remain the Collection kit's public fields.

| `item.companions` field | Default | Meaning |
|---|---|---|
| `movement` | `"walk"` | `walk`, `hop`, `fly`, or `hover` |
| `hoverHeight` | config value | Height for flyers and hoverers |
| `score` | `0` | Secondary ranking after rarity for equip best |
| `incomeBonus` | `0` | Additive contribution to the capped companion factor |
| `look` | absent | Static variant key applied before the copy's mutation |
| `idleAnimation`, `moveAnimation` | absent | Names of child Animation objects in the template |
| `triangles` | absent | Game-supplied triangle estimate for the whole model |

Numbers must be finite. Scores are 0..1e12, income bonuses 0..100, hover heights 0..1000;
triangle estimates are integers 0..1e9. Identifiers are nonempty strings up to 64 characters.
No item ids, positions, scores, bonuses or mutations are accepted from the client when equipping.

## Config

`GameConfig.config.Companions`:

| Key | Default | Meaning |
|---|---|---|
| `flag` | absent | Optional declared replicated feature flag |
| `slots` | `3` | Equip slots per player; integer 1..12 |
| `autoEquipBest` | `true` | Equip best on load and additions until the first manual choice |
| `assetsFolderName` | `"GameAssets"` | Direct child of ReplicatedStorage containing model templates |
| `maxDrawn` | `30` | Maximum live clones per client; integer 0..100 |
| `drawDistance` | `160` | Camera distance beyond which companions are hidden |
| `nearDistance` | `50` | Camera distance at which updates switch to `farHz` |
| `nearHz`, `farHz` | `30`, `10` | Near and far movement updates per second |
| `selectionHz` | `4` | Re-evaluate distances, streamed characters and draw selection |
| `lowDetailHz` | `10` | Maximum movement update rate in low detail |
| `spacing`, `behind` | `3`, `4` | Formation spacing and first row distance behind the owner |
| `followSpeed` | `10` | Exponential convergence rate |
| `teleportDistance` | `60` | Snap instead of smoothing past this distance |
| `hoverHeight` | `3` | Default height above the owner's ground level |
| `groundProbeUp`, `groundProbeDown` | `8`, `24` | Ground ray origin offset and downward length |
| `bobHeight`, `bobHz` | `0.25`, `1.5` | Cosmetic idle and flight bob |
| `hopHeight` | `0.75` | Maximum movement hop |
| `idleSpeed` | `0.5` | Owner speed below which idle animation is used |
| `incomeBonusEnabled` | `false` | Apply the capped factor through Economy |
| `bonusCap` | `3` | Maximum companion factor; 1..100 |

Rates are 1..60; positive distances are at most 10000, and `nearDistance <= drawDistance`.
Formation dimensions and probe lengths are positive and at most 1000. `followSpeed` is positive
and at most 100; bob and hop heights are 0..100, bob frequency is positive and at most 60,
and idle speed is 0..100. All numbers reject NaN and infinity. Bad configuration fails boot.

Leave the module out to disable it entirely; existing saves remain intact. A configured flag
can disable it during a session: actions are refused, bonuses become 1, public visuals disappear
and the default screen closes. Saved selections remain available when it is enabled again.
Inventory removal cleanup continues while the flag is off.

## Server API and actions

| API | Result |
|---|---|
| `equip(player, uid)` | `(ok, reason?)`; append one owned eligible copy |
| `unequip(player, uid)` | `(ok, reason?)`; remove one selected copy |
| `equipBest(player)` | `(ok, reason?)`; replace the set using server ranking |
| `equipped(player)` | Frozen `{ { uid, itemId, mutation? } }` in slot order |
| `bonus(player)` | Capped factor; 1 before load or while disabled |
| `refresh(player)` | `(ok, reason?)`; synchronously reconcile and invalidate the income factor |
| `registerLook(key, fn)` | Registration connection; server registry only |
| `applyLook(model, itemDef, mutation?)` | Apply the registered variant and mutation |
| `signals.EquippedChanged` | `(player, equippedCopies, factor)` after commit |

Failure reasons: `disabled`, `not_loaded`, `invalid_uid`, `not_owned`, `not_companion`, `locked`,
`already_equipped`, `slots_full`, `not_equipped`, `transaction_failed`.

Client actions are `actions.equip(uid)`, `actions.unequip(uid)` and `actions.equipBest()`.
Equip and unequip each allow 4 requests/second with burst 8; equip best allows 1/second with burst 2.
The server verifies ownership from Inventory's transaction view, eligibility, duplicate selections,
reservation predicates and available slots. One uid can occupy only one slot. Positions never
travel through these actions. There is no purchase operation or transaction API.

Extensions for dependent server modules:

- `canEquipWith(id, fn(player, copy) -> boolean) -> Connection`: every predicate must return true;
  exceptions deny access. A trade system that reserves copies must register this predicate and
  reserve first, call `refresh(player)`, then activate the offer only on success. Roll back the
  reservation on failure. Refresh must follow the reservation commit and precede offer acceptance;
  never call it inside an already-open transaction. It synchronously invalidates the income factor
  before returning, including when an equipped copy becomes reserved. The current Inventory has no
  separate reservation registry; pending gifts have already been removed from ownership.
- `scoreWith(id, fn(player, copy, itemDef) -> number) -> Connection`: add a secondary ranking score.
  Errors and nonfinite values contribute zero; negative values clamp to zero.

Callbacks must be synchronous and side-effect free. Registration ids must be unique.
Equip best orders by descending public rarity tier, then total score, then ascending uid.
Without Rarity it uses the merged theme's tier order; unknown tiers rank below known tiers.

## Saves, rebirth and replication

Save section `companions`, version 1:

```lua
{ equipped = { "copy-uid-a", "copy-uid-b" }, manual = false }
```

Only uid selections and the manual-choice marker are saved. Load sanitization removes malformed
values; server reconciliation drops missing, ineligible, reserved, duplicate and excess copies.
Any successful manual equip, unequip or equip-best action sets `manual = true`. An intentionally
empty selection stays empty on rejoin. Auto mode uses equip best on load and when an item is added
while `manual = false`; it never overrides a manual choice.

Inventory's public `onItemRemoved` extension clears a removed uid inside the same transaction,
covering selling, transfers, gifts and rebirth wipes. Rebirth's own inventory policy determines
which copies survive; Companions does not duplicate that policy or touch another save section.

The owner receives `data.equipped`, `data.manual`, `extra.bonus` and `extra.enabled`.
All clients receive `extra.roster`, a map keyed by decimal user id containing only
`{ userId, equipped = { { uid, itemId, mutation? } } }`. Every owner's list is bounded by the
validated slot limit. It never includes inventories, metadata, source tags, names or positions.
Equipment updates coalesce on a 0.25-second shared tick; unchanged rosters skip publication.
Load reconciliation flushes immediately before initial state; flag changes also flush immediately.
Starter additions defer to that load pass instead of equipping twice.

Client readers accept the full framework state:
`read.equipped(state)`, `read.manual(state)`, `read.bonus(state)`, `read.enabled(state)` and
`read.roster(state)`. Defaults are empty lists/maps, false manual/enabled, and factor 1.

## Following and streaming

Each client clones the selected templates and moves them locally with `PivotTo`. There are no
server physics companions. Walkers and hoppers snap to nearby ground; flyers and hoverers use
hover height. Smoothing uses actual elapsed time, including 1 Hz settings. `idleSpeed` is the owner-speed
threshold for moving versus idle. Ground placement uses model bottom relative to its pivot,
including off-center pivots. First appearance,
respawn and excessive separation snap immediately to the new owner formation.

Ground queries exclude characters and the local companion folder. Every cloned part, including
parts added by a look callback, has `CanCollide`, `CanQuery` and `CanTouch` false. Scripts,
Humanoids and physics movers are removed. Final sanitization covers the unparented root and
descendants, removes joints/constraints with external endpoints and external effect references,
and retains only internal rig Motor6Ds. The guarantee covers the returned tree; a trusted game
callback that directly changes other world objects cannot be sandboxed. Optional rigs retain Motor6Ds and an AnimationController
with Animator; rigid models need neither. Child Animation objects load once per clone, with tracks
stopped when culled or motion is reduced.

Mover constraints apply physics force or torque; direct local movement is the kit's deliberate
cosmetic implementation choice. [Mover constraints](https://create.roblox.com/docs/physics/mover-constraints),
[AlignPosition](https://create.roblox.com/docs/reference/engine/classes/AlignPosition),
[AlignOrientation](https://create.roblox.com/docs/reference/engine/classes/AlignOrientation).
AnimationController supports animated non-player objects; the kit uses Animator directly.
[AnimationController](https://create.roblox.com/docs/reference/engine/classes/AnimationController),
[Animator](https://create.roblox.com/docs/reference/engine/classes/Animator).

A character or root may be absent with streaming. Selection skips it without yielding and removes
its clones, then recreates them when it returns. A raycast miss uses a temporary owner-relative
height instead of falling. Templates live in ReplicatedStorage; the kit changes no world streaming
settings, requests no persistent characters and performs no pathfinding. Followers may pass through
obstacles. Streaming can unload Workspace content, and atomic grouping does not make later model
additions atomic. [Instance streaming](https://create.roblox.com/docs/workspace/streaming),
[Streaming techniques](https://create.roblox.com/docs/workspace/streaming/techniques).

## Performance on phones

At 50 players with three equipped copies, the roster has 150 small copy records, while each client
creates at most 30 models. Selection chooses nearest camera distance first, with stable user-id
and slot ties. At the 12-slot limit, 50 owners produce 600 candidates and roughly 120 KB of
bounded identifiers per snapshot before encoding overhead. Sustained churn can send four such
snapshots per second per established client; joins and flag changes flush immediately.
Distance culling happens before cloning. There is one update driver per client;
far companions update less frequently, and ground raycasts run only at their movement update rate.
With unusually long identifiers a default 50-player roster can approach 30 KB before encoding
overhead. Each changed roster is a full shared snapshot, so total broadcast traffic grows with
recipient count as well as equipped count; the kit sends no per-frame positions.

`setLowDetail(true)` caps updates at `lowDetailHz` and stops bobbing, hopping, rig tracks and effects.
`lowDetail()` returns the local toggle. Both `CoreReducedMotion` on the local player and
`GuiService.ReducedMotionEnabled` suppress decorative motion and tracks while keeping following.

`debugStats()` reports drawn/candidate/culled counts, parts, estimated triangles and unknown mesh
parts. Mesh triangles use the optional per-item art estimate; the kit cannot infer an exact triangle
count for arbitrary uploaded meshes. Supply a conservative estimate and measure on a low-end phone.
The kit caps model counts, not triangles or transparent-shell overdraw. Server console command
`companions debug [userId]` reports roster size, budgets and art estimates. Client command bar
`print(StudWork.use(Companions).debugStats())` reports local counters, including hook-added meshes.

The default equip screen uses icons or simple placeholders and pages at most 20 items. It creates
no ViewportFrames. A custom Index can clone a selected model and call `applyLook`; viewport images
need their own model rendering, so avoid animating a whole inventory of them.
[Viewport frames](https://create.roblox.com/docs/ui/viewport-frames).
The bounded update rates follow the recommendation to limit expensive frame-event work;
actual device budgets still require profiling.
[Improve performance](https://create.roblox.com/docs/performance-optimization/improve).

## Looks shared with Plot and thumbnails

Register a function by variant or mutation key:

```lua
companions.registerLook("Gilded", function(model, _itemDef)
    -- Apply your game's mesh material, texture or colour rules here.
end)
```

Registration returns a connection with `Disconnect()`. Each registry rejects duplicate keys.
The static item look runs first, then the copy's mutation; the same key runs only once.
Callbacks are protected, synchronous and receive a fresh clone, never the asset template.
A registration change rebuilds affected visuals rather than layering edits on old clones.

Server and client registries are separate. Put the appearance function in a shared game module
and register it on both sides: client for followers and thumbnails, server for Plot displays.
Inside a server module, call `ctx.deps[Companions].registerLook` from `start(ctx)`,
when dependency APIs are available; use `init(ctx)` only for extension registration.
Require the shared appearance module at file scope before these non-yielding lifecycle callbacks.
With Plot enabled, Companions registers a generic public `Plot.extensions.decorate` extension during initialization. That hook accepts
any dependent module, runs before measuring and positioning the display, and re-sanitizes the
result after decoration. It does not make Plot depend on Companions. The connection supplies
`Disconnect()` and `Invalidate()`; invalidation refreshes displays once without changing callback
order. Failed callbacks may leave sanitized partial results. Destroyed or empty visuals use a safe
primitive fallback; arbitrary edits are not rolled back.

Viewport looks should modify visible mesh appearance; do not rely on world-only effects.
Keep callback-added parts within your game's art budget.

## Bonuses and luck

Bonuses are opt-in: by default equipping changes only appearance. The server computes
`min(bonusCap, 1 + sum(equipped item incomeBonus))`. The cap applies to this companion factor;
Economy's other multipliers retain their own behavior. With `incomeBonusEnabled = true` and
Economy enabled, one public `Economy.rateFactor` provider supplies it. Repeated equips never
create extra multiplier records, and no companion bonus is saved in Economy.

A game can observe `EquippedChanged` for a custom effect. Any effect that changes luck must
compose all luck sources on the server and call `Rarity.setLuck`, so displayed session odds stay
accurate. For per-item luck, call `Rarity.discloseItem` and roll that same item key at exactly the
disclosed luck. Never pass a hidden luck argument to a paid roll. The kit itself does not roll
items or change luck. See [Collection](collection.md#rarity) and
[paid-random guardrails](../guardrails.md#paid-random-compliance).

## UI and overrides

The default `Companions` screen supplies equip, unequip, equip best and paging, with slot usage and
an empty state. It uses theme tokens, `Companions.*` localization keys and touch-sized controls.
A HUD widget `Companions.open` opens it. Replace the screen with
`UI.registerScreen("Companions", MyScreen)` or remove the widget with
`client.hud.widgets["Companions.open"] = false`. The module preserves a screen registered before
its own startup. Settings screens can call `setLowDetail` without networking or save changes.

For other formations, renderer behavior or game rules, replace the appropriate game-facing piece
or write a normal module using the same public APIs. Nicknames and player-authored text are absent.
No text filtering or chat access is needed for this kit.

## Registration examples

Declare an optional public flag in GameConfig and reference it in the module config:

```lua
flags = { companions = { default = true } },
config = { Companions = { flag = "companions" } },
```

After `StudWork.start`, register the same shared game appearance function in both server and
client entry points; their registries are independent:

```lua
local looks = require(ReplicatedStorage.Game.CompanionLooks)
StudWork.use(Companions).registerLook("Gilded", looks.gilded)
```

A server module declares Companions as a dependency and registers reservation validation in init:

```lua
ctx.depsExt[Companions].canEquipWith("trade", function(player, copy)
    return not tradeReservations.isReserved(player, copy.uid)
end)
-- After committing a reservation, before activating its offer:
local ok = ctx.deps[Companions].refresh(player)
if not ok then
    tradeReservations.release(player, uid)
    return false
end
```

Version 1 normalizes malformed fields, deduplicates bounded uid lists and defaults manual to false.
Ownership validation follows loading and never directly reads the Inventory save section.
