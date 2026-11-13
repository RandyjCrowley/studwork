# Companions: pending shared-file additions

These are integration-ready additions for the shared files, held here to avoid conflicting with
other changes. This document does not change the release version. Implementation and gate evidence
must be checked before applying the entries. No shared file has been edited for this document.

## CHANGELOG.md — under Unreleased / Added

- Optional Companions kit: server-validated copy-uid equipment, saved selections, equip best,
  transaction-safe ownership cleanup and capped opt-in income bonuses; local following with
  formations, ground snapping, motion preferences, distance budgets, reusable variant looks and a
  themed touch equip screen.
- Plot's public `extensions.decorate(id, fn) -> DecoratorConnection` extension lets dependent modules style cloned
  displays before measurement, with existing-display refresh and collision sanitization.

## docs/decisions.md — append

### Companions use local cosmetic followers and authoritative equipment

Equipment and capped bonuses belong to the server; clients animate only bounded copies of the
replicated equipped set. No client position enters gameplay state. Direct `PivotTo` movement avoids
physics assemblies for a cosmetic system. Roblox describes `AlignPosition` as force-driven and
`AlignOrientation` as torque-driven; these are useful physical movers but unnecessary for this kit.
[AlignPosition](https://create.roblox.com/docs/reference/engine/classes/AlignPosition),
[AlignOrientation](https://create.roblox.com/docs/reference/engine/classes/AlignOrientation),
[mover constraints](https://create.roblox.com/docs/physics/mover-constraints),
[PVInstance.PivotTo](https://create.roblox.com/docs/reference/engine/classes/PVInstance#PivotTo).

No Humanoid or pathfinding is required. Optional rigs use AnimationController and Animator, while
rigid models use the same movement maths. Pathfinding computes routes around obstacles; cosmetic
followers intentionally permit clipping rather than maintaining paths per equipped copy.
[AnimationController](https://create.roblox.com/docs/reference/engine/classes/AnimationController),
[Animator](https://create.roblox.com/docs/reference/engine/classes/Animator),
[pathfinding](https://create.roblox.com/docs/characters/pathfinding).

Streaming can remove Workspace content. Missing character roots skip rendering, missing ground
uses an owner-relative fallback, and templates remain in ReplicatedStorage. No persistent-model
requests or forced streaming settings are introduced. Atomic models are not a guarantee for new
children added after replication.
[Instance streaming](https://create.roblox.com/docs/workspace/streaming),
[streaming techniques](https://create.roblox.com/docs/workspace/streaming/techniques),
[ModelStreamingMode](https://create.roblox.com/docs/reference/engine/enums/ModelStreamingMode).

The default UI uses icons and bounded pages. A ViewportFrame renders another model view; custom
thumbnail UIs should bound their active previews. Companions reuse appearance functions with Plot
through a generic decorator extension rather than introducing a reverse kit dependency. Tags on
cloned art are not used for discovery, and no read-only tag property is assigned; tag operations
use CollectionService methods if needed.
[ViewportFrame](https://create.roblox.com/docs/reference/engine/classes/ViewportFrame),
[viewport frames](https://create.roblox.com/docs/ui/viewport-frames),
[CollectionService](https://create.roblox.com/docs/reference/engine/classes/CollectionService).

One client driver, distance-dependent update rates and a default maximum of 30 clones bound
movement work. Device render cost still depends on art, transparency and rig complexity.
[Improve performance](https://create.roblox.com/docs/performance-optimization/improve).

The kit's only cross-kit modification is Plot's generic decorator extension. Owned-copy removals
already offer a public transactional hook; income already offers a public rate-factor hook. Neither
framework internals nor other modules' save sections are needed. Luck stays in Rarity's disclosed
public APIs; companions never introduce their own hidden roll modifier.

## docs/known-issues.md — append under Low

### Companion rendering still needs device and streaming coverage

- **Where:** Companions client following and custom game model art.
- **Behavior:** the kit bounds selected model count and update frequency. Actual mesh triangles,
  transparent shells, custom effects and Animator work remain asset-dependent. Mesh triangle counts
  in diagnostics are game estimates, with unknown meshes reported separately.
- **Check:** measure on a low-end phone and with many players under StreamingEnabled. A real
  two-player local server remains necessary to verify each player sees the other's companions.
- **Trade integration:** the current Inventory removes pending gifts from ownership but exposes no
  separate reservation registry. A custom trade module must register `canEquipWith` and refresh
  immediately when its reservations change.
- **Visual limitation:** local followers can pass through obstacles. They intentionally do not
  compute navigation paths or affect gameplay positions.

## docs/framework/module-reference.md — append kit link

### Companions kit

See [Companions](../framework/kits/companions.md) for saved equipment, following, bonuses, appearance hooks,
settings and screen overrides. It is a normal optional module using the existing public context.
There are no new framework context members.

## docs/framework/kit-contract.md — append

## Companions kit

### Companions (needs Items and Inventory)

- **api:** `equip(player, uid) -> (ok, reason?)`, `unequip(player, uid) -> (ok, reason?)`,
  `equipBest(player) -> (ok, reason?)`, `equipped(player) -> { { uid, itemId, mutation? } }`
  (frozen), `bonus(player) -> number`, `refresh(player) -> (ok, reason?)`,
  `registerLook(key, fn(model, itemDef)) -> Connection`, `applyLook(model, itemDef, mutation?)`.
- **extensions:** `canEquipWith(id, fn(player, copy) -> boolean) -> Connection`,
  `scoreWith(id, fn(player, copy, itemDef) -> number) -> Connection`. Synchronous; unique ids.
  Reservation predicate errors deny; malformed scores contribute zero.
- **signals:** `EquippedChanged(player, equippedCopies, factor)` after commit.
- **Uses:** Inventory's `onItemRemoved` for atomic cleanup; optional Economy `rateFactor`, Rebirth
  `resetStep`, Rarity public tier order, and Plot `decorate` for display appearance.
- **No txApi or purchaseOps.** Client actions `equip(uid)`, `unequip(uid)` (4/s burst 8 each),
  `equipBest()` (1/s burst 2), using its own network declaration.
- **Save section:** `companions`, version 1, `{ equipped = { uid }, manual = false }`.
  Replicated owner `data.equipped`, `data.manual`; owner `extra.bonus`, `extra.enabled`;
  all-client `extra.roster` of bounded equipped metadata, without positions or inventories.
- **Client:** `open()`, `setLowDetail(boolean)`, `lowDetail()`, `debugStats()`, `registerLook`,
  `applyLook`, `read.equipped/manual/bonus/enabled/roster(state)`. Screen `Companions`,
  widget `Companions.open`. Server/client appearance registrations are separate.

### Plot — additive extension under existing Base kit entry

- **extensions:** `decorate(id, fn(visual, itemDef, instance)) -> DecoratorConnection`: synchronous public
  display decorator, called before size measurement and placement. Unique id; stable order; protected errors;
  registration or disconnect refreshes existing displays. The result is sanitized for scripts and
  collisions and external references after decoration while unparented. Failures leave sanitized
  partial results; destroyed visuals use a primitive fallback. Connection `Invalidate()` refreshes
  once without changing order. Register during init. Plot has no dependency on the calling module.

## docs/framework/module-api.md — no framework addition

No new framework API or context capability is required. Link the kit page from the kit directory
index only; the new Plot extension belongs to the kit contract.

## docs/README.md and root README.md — kit links

Add alongside existing optional kit links:

```markdown
- [Companions](framework/kits/companions.md): saved copy equipment and bounded local followers.
```

For a link in the root README use `docs/framework/kits/companions.md` as its target.

## tools/new-project and tools/new-game — exact module examples

Module discovery reads kit definitions, so these shell wrappers need no hard-coded module-list
change. Add these usage examples to their documentation where module examples are listed:

```sh
tools/new-project my-game --modules Items,Inventory,Companions --no-install
tools/new-game my-game --modules Items,Inventory,Companions
```

`tools/lune/KitModules.luau` discovers Companions; verify dependencies are added when specifying
`--modules Companions`. Do not create a second static module list.

## Sandbox and template snippets

For `examples/sandbox/src/shared/Config/init.luau` and
`templates/new-game/src/shared/Config/init.luau`, add to `modules` after Inventory:

```lua
require(Modules:WaitForChild("Companions"):WaitForChild("module")),
```

For sandbox `src/shared/Config/Balance.luau` add:

```lua
Companions = { slots = 3, incomeBonusEnabled = false },
```

For `templates/new-game/src/shared/Config/Balance.luau` add:

```lua
-- @if Companions
Companions = { slots = 3, incomeBonusEnabled = false },
-- @end
```

For the existing pebble, twig and acorn entries in each game's Config/Items, add the matching field:

```lua
companions = { movement = "walk" }, -- pebble
companions = { movement = "hop" }, -- twig
companions = { movement = "fly" }, -- acorn
```

Use the template's marker form on the respective lines so projects omitting the module remain valid:

```lua
companions = { movement = "walk" }, -- @if Companions
companions = { movement = "hop" }, -- @if Companions
companions = { movement = "fly" }, -- @if Companions
```

These are fields inside three different existing item tables. Primitive placeholders make a valid
asset-free demo. Optional model fixtures should be built from parts in the game world setup;
no uploaded asset dependency is needed. Open the screen with:

```lua
StudWork.use(Companions).open()
```

No custom keybinding is required because the kit contributes its own HUD widget. Add Companions
to any explicit all-kits bench module list at integration time, with 50 players and 3 equipped
copies each; the kit's isolated benchmark reports the same load without editing shared variants.

## Other-kit and regenerated files

Planned additive changes only:

- `packages/kits/base/Plot/server/init.luau`: publish/call `decorate` and refresh display visuals.
- `packages/kits/base/Plot/server/Decorators.luau`: generic ordered callback registry.
- `packages/kits/base/Plot/server/Decorators.spec.luau` and `DecoratorsIntegration.spec.luau`:
  callback ordering, late registration/disconnect refresh, error containment, size before placement,
  and collision/script sanitization.
- `packages/kits/base/Plot/README.md`: public extension contract.

No `packages/framework/`, `packages/ui/`, other kit or shared bench file is required.
`tools/lune/NewGame.spec.luau` adds the discovered Companions entry and updates the manifest
count from 15 to 16; its dependency assertion explicitly checks Items and Inventory.
The foundation regenerated these mappings with `tools/sync-projects`:
`examples/modules/session-leaderboard/tests/fixture-game/default.project.json`,
`examples/overrides/ov-a/default.project.json`, `examples/overrides/ov-b/default.project.json`,
`examples/overrides/ov-c/default.project.json`, `examples/overrides/ov-d/default.project.json`,
`examples/overrides/ov-e/default.project.json`, `examples/overrides/ov-f/default.project.json`,
`examples/sandbox/default.project.json`, `examples/sandbox/foundation-only.project.json`,
and `templates/new-game/default.project.json`. These add module paths without enabling it.

## docs/manual-qa.md — append checklist

- Equip three copies: walker, hopper and flyer; follow on flat ground, stairs and a moving platform.
- Respawn and teleport; each clone snaps back without crossing the world by smoothing.
- Enable a variant hook on server and client; confirm follower, Plot and custom thumbnail agree.
- Check the equip screen at desktop and 667x375, including paging, empty state and full slots.
- Toggle reduced motion and low detail; decorative motion and tracks stop, following remains.
- Toggle the kit's flag off/on; actions/bonus/visuals follow it while saved selections remain.
- In a real two-player local server, both clients see the other's companions.
- Profile a low-end phone and a busy streamed scene; capture triangles, effects and frame cost.
