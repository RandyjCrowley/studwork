# Carry kit (v1.8.0): Carry, Movement

New kit folder `packages/kits/carry/` with two modules:

- **Carry:** pick up, carry, hand off, throw, drop and deliver an object, alone or with other players.
- **Movement:** a server-side movement validator for player characters. Carry uses it, and so can any
  game code.

Neither module depends on the other. Carry reaches Movement only through `optional = { Movement }`,
public reads and public signals, and it works without Movement (see "Carry × Movement"). Both are
normal kit modules on the public module API ([module-api](../module-api.md),
[module-reference](../module-reference.md), [kit-contract](../kit-contract.md)). **No framework file
changes.** The only test seam is kit-owned (see "The World seam").

"Hard rule N" below means the numbered hard rules in the repo's `CLAUDE.md`.

**Doc URLs relied on** (also cited in `docs/decisions.md`):
- Network ownership: https://create.roblox.com/docs/physics/network-ownership
- AlignPosition / AlignOrientation (the rejected option):
  https://create.roblox.com/docs/physics/constraints/align-position,
  https://create.roblox.com/docs/physics/constraints/align-orientation
- Raycasting (`WorldRoot:Raycast`, `RaycastParams.CollisionGroup`, filters):
  https://create.roblox.com/docs/workspace/raycasting
- `WorldRoot:Blockcast` / `Shapecast`: https://create.roblox.com/docs/reference/engine/classes/WorldRoot
- `RunService` frame events (`Heartbeat`): https://create.roblox.com/docs/reference/engine/classes/RunService
- Humanoid (`SeatPart`, `WalkSpeed`, `JumpPower`/`JumpHeight`, `HipHeight`, `Died`) and
  `HumanoidStateType`: https://create.roblox.com/docs/reference/engine/classes/Humanoid,
  https://create.roblox.com/docs/reference/engine/enums/HumanoidStateType
- `Seat` / `VehicleSeat` / `SeatWeld`: https://create.roblox.com/docs/reference/engine/classes/Seat
- `Player:GetNetworkPing`: https://create.roblox.com/docs/reference/engine/classes/Player
- `Workspace.FallenPartsDestroyHeight`, `Workspace.Gravity`:
  https://create.roblox.com/docs/reference/engine/classes/Workspace
- Collision groups: https://create.roblox.com/docs/workspace/collisions
- Streaming (`StreamingEnabled`, `ModelStreamingMode`): https://create.roblox.com/docs/workspace/streaming
- `vector` library: https://create.roblox.com/docs/reference/engine/libraries/vector
- `ContextActionService` (wrapped by the framework's `StudWork.Client.Input.bind`):
  https://create.roblox.com/docs/reference/engine/classes/ContextActionService
- `CollectionService`: https://create.roblox.com/docs/reference/engine/classes/CollectionService

---

## Quickstart: getting a carriable into your game

1. **List the modules.** Pass both to the generator (`tools/new-project my-game --modules Carry,Movement`,
   or `tools/new-game`), or add them by hand to `GameConfig.modules` in `src/shared/Config/init.luau`
   and to your boot spec's `EXPECTED` list. `"Carry"` and `"Movement"` are two separate modules.
   Neither needs a `dependsOn` entry from your own game module unless your game code calls their
   APIs directly (most carry games do, to react to `PickedUp`/`Delivered`).
2. **Define a carriable.** Pick a CollectionService tag name (e.g. `"Couch"`) and add it to
   `config.Carry.carriables` in your `Balance.luau`:
   ```lua
   Carry = {
   	carriables = {
   		Couch = { massClass = "heavy", carriers = { min = 2, max = 2 },
   			gripPoints = { { -1.5, 1, 0 }, { 1.5, 1, 0 } } },
   	},
   },
   ```
   Then put a `CollectionService:AddTag(part, "Couch")` on the Model/BasePart you want players to
   carry (in your world-build script, or directly in Studio with the Tag Editor plugin). The tag
   name and the `carriables` key **must match exactly** — there's no registration call beyond
   listing it in config; Carry discovers tagged instances through `onTagAdded`.
3. **Tag a delivery zone.** Tag any part `"CarryDelivery"` (the `deliveryTag` default — override
   it in config if you want a different name). No other wiring needed; Carry tests every
   `carried` object against every tagged zone each logic tick (see "Delivery").
4. **Wire a timed run (Movement).** Connect `ctx.deps[Carry].signals.PickedUp:Connect(function(player)
   Movement.startRun(player, runId) end)` and `ctx.deps[Carry].signals.Delivered:Connect(function(object,
   zone, carriers) for _, p in carriers do local eligible, strikes = Movement.endRun(p, runId) ...
   end end)` — **run state is per player**, so with N carriers you `startRun`/`endRun` once per
   carrier, and `endRun` returns `(eligible: boolean, strikes: { Strike })`. **Important: at the
   shipped defaults every check's `response` is `"log"`, which means `endRun.eligible` is always
   `true`** — Movement only starts affecting anything once you set `config.Movement.responses` for
   the checks you want enforced (e.g. `responses = { teleport = "disqualifyRun", speed =
   "disqualifyRun" }`). See "Response policy" below for exactly what each response level does.
   **A disqualified carrier is released by Carry and never reaches `Delivered`,** so your game's
   `endRun` for that player never gets called by the `Delivered` path above — call it directly
   from `Movement.signals.RunDisqualified` instead (or from `Carry.signals.Dropped` when
   `reason == "disqualified"`), so every started run is eventually ended.
5. **Testing your own wiring.** The kit's own `FakeWorld` (`packages/kits/carry/tests/`) isn't
   Rojo-mapped and isn't a public API — don't require it from game code, but reading its source
   is a reasonable reference for writing your own. A spec that exercises an actual delivery needs
   most of the `World` type (see "The World seam") — roughly two dozen members across both
   modules, not a small subset: `clock`, `players` (must return a plain **array** of `Player`,
   not the harness's userId-keyed map — convert it), `rootOf`, `humanoidFacts`, `seatOf`, `ping`,
   `gravity`, `killY`, `cast`, `blockcast`, `boundsOf`, `surfaceVelocityOf`, `tagged`,
   `onTagAdded`/`onTagRemoved`, `onCharacter`, `onServerMove`, `setCFrame`, `setRootCFrame`,
   `anchor`/`unanchor`, `setCollide`, `setQuery`, `setCollisionGroup`, `velocityOf`, `setVelocity`,
   `setWalkSpeed`, `setAttribute`, `kick`. **Contract for `onCharacter`: your fake must call
   `fn("added", character)` for every player already present when a module subscribes** (most
   naturally: synchronously, right when `onCharacter` is called) **or Movement never produces a
   sample for that player**, and every Carry action then refuses with `"untrusted"` or
   `"noCharacter"` with no further log line — this is the single most common stuck point writing
   a fake `World`. Install your fake with `Carry.useWorld(yourFake)` / `Movement.useWorld(yourFake)`
   inside a `StudWork.test.harness` spec; both modules idle safely with no adapter installed
   otherwise (default boot under the harness, no error). To assert on a game module's own
   replicated data from the same spec, read `h:state(player).modules.<YourGameModule>.data.<field>`
   (the harness's state-reading convention, not specific to this kit).

## The World seam (both modules; a deliberate, kit-owned test seam)

Every check needs world facts: characters, positions over time, ping, casts, tags, seat welds. The
Lune harness has none of these. Its Workspace is empty, it has no `CFrame`, and
`GetService("CollectionService"/"RunService")` errors. So each module reads the world **only through
a `World` adapter object**. This is a test seam owned by the kit, not a framework hook.

- **Live adapter:** `<Module>/shared/World.luau`, `World.live()`. It fetches Workspace,
  CollectionService, RunService and Players **lazily, the first time a tick needs them**, inside a
  `pcall`. It never does this at module load and never in `init`. If the services aren't available
  (the harness, `test-adopt`, a new-game boot spec), `World.live()` returns `nil`. The module then
  idles: it samples nobody, carries nothing and logs once at debug level. So "boot every module at
  defaults" keeps working.
- **Fake adapter:** `packages/kits/carry/tests/FakeWorld.luau`, which is scriptable. It provides
  characters on scripted paths, a latency and jitter model, boxes for casts, tags, seats and a ping.
  It also **counts** casts and CFrame writes, so the bench can price them. Specs, sims and the bench
  variant use it. It lives in `tests/`, which isn't Rojo-mapped.
- **Installing:** `Movement.useWorld(world)` and `Carry.useWorld(world)` are public, additive API
  documented as a test seam. A spec calls them right after the harness boots. They may be called at
  any time: the adapter is swapped and all per-player and per-object baselines are cleared, which is
  the same as flipping the flag off and on.
- **Geometry types:** positions are Luau `vector` values. Orientation is the kit's own tiny
  `shared/CF.luau` (position plus a rotation matrix, with `fromParts`, `mul`, `inverse`, `lerp`,
  `lookAlong`), so all the pure math (blend, clamp, arcs, sweeps) runs in Lune. Only the live adapter
  converts to and from `CFrame`/`Vector3`.

```lua
export type HumanoidFacts = {
  alive: boolean, walkSpeed: number, jumpVelocity: number, -- JumpPower, or sqrt(2*g*JumpHeight)
  hipHeight: number, rootHalfHeight: number, state: string, -- state is informational only, never an exemption
  collisionGroup: string?, -- the root part's CollisionGroup: Movement's casts use it as the character's group
}
export type Hit = { instance: any, position: vector, normal: vector, distance: number }
export type World = {
  clock: () -> number,                                      -- monotonic seconds (live: os.clock())
  players: () -> { Player },
  rootOf: (player: Player) -> (vector?, CF?),               -- nil: no character, no root, or not in Workspace
  humanoidFacts: (player: Player) -> HumanoidFacts?,        -- server-side Humanoid properties
  seatOf: (player: Player) -> (any?, CF?),                  -- only a server-side Seat/VehicleSeat holding a SeatWeld to this root
  ping: (player: Player) -> number,                         -- seconds, round trip (live: GetNetworkPing; 0 if unknown)
  gravity: () -> number,                                    -- Workspace.Gravity (server)
  killY: () -> number,                                      -- Workspace.FallenPartsDestroyHeight
  cast: (origin: vector, dir: vector, opts: CastOpts) -> Hit?,             -- Raycast
  blockcast: (cf: CF, size: vector, dir: vector, opts: CastOpts) -> Hit?,  -- Blockcast
  boundsOf: (inst: any) -> (CF, vector),                    -- pose CF and size (part: CFrame/Size; model: GetBoundingBox, the box CENTER)
  surfaceVelocityOf: (inst: any) -> vector,                 -- anchored part's AssemblyLinearVelocity (conveyors), else zero
  tagged: (tag: string) -> { any },
  onTagAdded: (tag: string, fn: (any) -> ()) -> () -> (),   -- returns a disconnect
  onTagRemoved: (tag: string, fn: (any) -> ()) -> () -> (),
  onCharacter: (player: Player, fn: (event: "added" | "removing" | "died", character: any) -> ()) -> () -> (),
  onServerMove: (player: Player, fn: (cf: CF) -> ()) -> () -> (), -- root CFrame written by a SERVER script (see Movement "Server moves")
  setCFrame: (inst: any, cf: CF) -> (),                     -- part.CFrame / model:PivotTo
  setRootCFrame: (player: Player, cf: CF) -> (),            -- Movement.teleport and resetPosition
  anchor: (inst: any) -> (), unanchor: (inst: any) -> (),   -- unanchor also SetNetworkOwner(nil) once unanchored
  setCollide: (inst: any, on: boolean) -> (), setCollisionGroup: (inst: any, group: string) -> (),
  setQuery: (inst: any, on: boolean) -> (),                 -- CanQuery (every part of a model); off while carried
  velocityOf: (inst: any) -> vector,                        -- server-simulated (server-owned) assemblies only
  setVelocity: (inst: any, v: vector) -> (),
  setWalkSpeed: (player: Player, speed: number) -> (),
  setAttribute: (inst: any, name: string, value: any) -> (),
  kick: (player: Player, message: string) -> (),
}
export type CastOpts = { exclude: { any }?, collisionGroup: string?, ignoreCharacters: boolean?,
  respectCanCollide: boolean? } -- RaycastParams.RespectCanCollide: skip CanCollide = false parts
```

Each module's live adapter implements only the members it uses. The type is spelled the same in both,
and the fake implements all of them. Carry and Movement never share Lua state: each installs and
fetches its own adapter.

## Clocks and tick order (both modules)

- **Time:** every timing decision uses `world.clock()`, which is `os.clock()` live and scripted in
  fakes. Neither `ctx.now()` (1 s resolution) nor the `dt` argument of `onTick` is used: that argument
  is the nominal interval, and after a hitch the shared ticker calls a handler up to 10 times in the
  same frame. `dt` is always `clock() - lastSampleAt`.
- **Skipping catch-up calls:** a call that finds `dt < 0.5 / sampleHz` does nothing, for that player
  or object. Probe: a 0.45 s hitch gives one real sample plus 4 skipped calls, with no strike.
- **Order:** Movement samples first in every tick. Carry always reads the **most recent completed**
  Movement sample (`lastValid`), never a raw position, for every decision: motion, pick-up, hand-off,
  catch and delivery. Running in the same frame or one frame later doesn't matter, because Carry
  never waits for Movement.

---

## Carry

### Decision: anchored, CFrame-driven, interpolated on the shared Heartbeat ticker

This decision is also recorded in `docs/decisions.md`.

**While carried, the object is anchored.** `CanCollide` is off only so the carriers' own characters
don't bump into it: being anchored is what holds it in place. `CanQuery` is off too, in lockstep with
`CanCollide` (every way out of `carried` turns both back on), so no raycast that ignores `CanCollide`
(the engine default, e.g. a game's own anti-cheat) hits the object sitting in front of its carrier. Carry writes its CFrame (a
`CFrame` set for a part, `PivotTo` for a model):
- at `motionHz` (default 30) from `ctx.lifecycle.onTick(1 / motionHz)`, which runs on Heartbeat;
- each time interpolating between the last two **clamped** targets that Carry's logic tick
  (`sampleSeconds`, 10 Hz) computed.

Why this design:
- **Anchored parts are always server-owned.** No `SetNetworkOwner` call is needed. That call *errors*
  on anchored parts, so Carry makes it only after unanchoring on a drop.
- **The object doesn't free-fall between writes** and can't fall through the floor on a server hitch.
  An unanchored, non-colliding part would fall 0.98 studs per 0.1 s.
- **Clients see a smooth glide, not 10 Hz steps.**

There is exactly one timing surface: Heartbeat, through the framework's shared ticker.

Why not `AlignPosition`/`AlignOrientation`: those need an unanchored, simulated body, which costs a
physics step per object and settles non-deterministically. The blend would then stop being a pure
function the sims can assert on. A client never drives the object. A client only sends requests and
renders cosmetic wobble that never replicates.

`BulkMoveTo` isn't needed at this scale (20 objects).

### Config (`config.Carry`)

| Key | Default | Meaning |
|---|---|---|
| `flag` | none | feature flag ([environments](environments.md)). Turning it off live releases every object (see "Flags, leaving, rejoining") |
| `sampleSeconds` | `0.1` | Carry's logic tick: clamp, drop rules, catches, delivery, kill plane |
| `motionHz` | `30` | how often carried objects' CFrames are written (interpolated). The budget knob for motion |
| `carriables` | `{}` | `{ [tag]: CarriableDef }`, keyed by a CollectionService tag (below) |
| `dropRules` | below | the global default. `carriables[tag].dropRules` overrides per field |
| `deliveryTag` | `"CarryDelivery"` | CollectionService tag for delivery-zone parts |
| `deliveryContainment` | `"full"` | `"full"`: the object's whole box must be inside the zone box. `"center"`: its pivot must be |
| `deliveryReachStuds` | `6` | each carrier's accepted position must be inside the zone box grown by this |
| `pickUpRadius` | `6` | the default for `CarriableDef.pickUpRadius`. Measured from the player's accepted position to the closest point of the object's box |
| `agree` | `{ baseStuds = 2, sampleAgeSeconds = 0.1, lagSeconds = 0.6 }` | for pick-up, hand-off and catch the raw root must also be within `agreeStuds = baseStuds + max(16, server WalkSpeed) × (sampleAgeSeconds + lagSeconds)` of the accepted position: **13.2 studs** at WalkSpeed 16, 24.4 at 32. `sampleAgeSeconds` is how old an accepted sample can be (Movement's `1 / sampleHz`); `lagSeconds` is a freeze-then-catch-up the accepted sample hasn't seen yet (Movement's `teleport.minLagSeconds`). So a game speed boost doesn't turn into `"disagree"` refusals (probe: largest legitimate gap 9.33 / 18.67 studs at WalkSpeed 16 / 32 on 300 ms with jitter) |
| `handOffRange` | `8` | adjacent hand-off: giver and receiver accepted positions within this of each other |
| `throwRange` | `40` | a throw needs the receiver within this. Beyond it, `handOff` is refused (`"tooFar"`) |
| `throwSpeed` | `40` | studs/s at which a throw leaves the thrower's hold point |
| `catchRadius` | `5` | the receiver's accepted position within this of the thrown object completes the catch |
| `catchWindowSeconds` | `1.2` | how long a thrown object stays catchable before it becomes a plain drop |
| `maxObjects` | `20` | objects in `gathering`, `carried` or `thrown` at once. A pick-up beyond this is refused (`"capacity"`) |
| `holdOffset` | `{ 0, 0.5, -2.5 }` | carrier-root-local point where the hands are (studs; −Z is forward) |
| `massClasses` | `{ light = { speedFactor = 1, throwable = true }, medium = { speedFactor = 0.85, throwable = true }, heavy = { speedFactor = 0.7, throwable = false } }` | per class: the WalkSpeed factor while carrying, and whether `handOff` may throw |
| `applyWalkSpeed` | `true` | while carrying, Carry multiplies the carrier's server-side `Humanoid.WalkSpeed` by `speedFactor × (1 − speedPenalty × missingCarriers)`, and divides it back on release |
| `clamp` | `{ speedSlack = 1.35, maxDtSeconds = 0.5, gripBreakStuds = 12, maxFallSpeed = 200, riseSlack = 1.15 }` | Carry's own displacement clamp (see "Object motion"). Applies with or without Movement |
| `killMarginStuds` | `50` | the default kill plane for dropped and thrown objects: `FallenPartsDestroyHeight + killMarginStuds` (per carriable: `killY`). It must be at least `½ × Gravity × (sampleSeconds + killHitchSeconds)²` (35.3 at the default Gravity): raise it for Gravity above about 277 |
| `killHitchSeconds` | `0.5` | how far past the next logic tick the kill plane looks ahead, to cover a server hitch (see "After a drop") |
| `settle` | `{ speedStuds = 0.5, seconds = 1 }` | a dropped object re-anchors once its server-simulated speed has stayed under `speedStuds` for `seconds` |
| `dropNoCollideSeconds` | `nil` | opt-in escape hatch only: when set, ALSO disables `CanCollide` for this long after a drop (on top of the default collision group), risking a fall-through on thin floors. Leave `nil` unless you can't use collision groups |
| `collisionGroup` | `"CarryDropped"` (built in, excludes characters only) | the collision group assigned to every dropped/thrown carriable; a game may override it (e.g. to also exclude NPCs). `CanCollide` is always `true` — world/floor collision is never disabled by default |
| `wobble` | `{ enabled = true, maxDegrees = 9, hz = 2.2, damping = 0.6 }` | client-only cosmetic spring, read by the client part through its `ctx.config`. Nothing is replicated per tick |
| `bindings` | `{ interact = { keys = { "E" }, gamepad = { "ButtonX" } }, pass = { keys = { "F" }, gamepad = { "ButtonY" } } }` | `Enum.KeyCode` names. Both also get on-screen touch buttons (see "Client") |

**`CarriableDef`** (`carriables[tag]`):

| Field | Default | Meaning |
|---|---|---|
| `model` | none | if set, only tagged instances whose `Name` equals it are carriables. This guards a tag reused on unrelated parts |
| `massClass` | `"medium"` | a key of `massClasses` |
| `carriers` | `{ min = 1, max = 1 }` | integers, `1 ≤ min ≤ max ≤ 8` |
| `gripPoints` | `{ { 0, 0, 0 } }` | object-local `{x, y, z}` per slot. The length must equal `carriers.max` (a boot error otherwise) |
| `speedPenalty` | `0` | 0..1: the fraction of walk speed lost per missing carrier below `max` |
| `fragility` | `1` | 0..1: scales the tilt and stretch thresholds (1 = as configured, 0 = never drops from tilt or stretch) |
| `pickUpRadius` | `config.pickUpRadius` | studs |
| `killY` | derived | an absolute kill-plane height for this carriable |
| `dropRules` | none | per-field override of `config.dropRules` |

**`dropRules`** defaults are `{ belowMin = true, tiltDegrees = 50, stretchStuds = 8, hardLandingSpeed = nil (off),
hardLandingMarginStuds = 4, carrierDied = true, carrierLeft = "drop", carrierDisqualified = "runDisqualified",
untrustedCarrier = true, hazard = false }`.
Every rule is optional, and `nil`/`false` means that rule never drops the object. `stretchStuds` is 8 (it
was 6) because two carriers' accepted positions can differ by up to `walk × jitter` ≈ 4.8 studs on a
300 ms connection. `carrierDisqualified` is `"off" | "runDisqualified" | "strike"` (see "Carry ×
Movement").

### States (frozen)

A tagged, valid carriable gets `CarryObjectId` when Carry **first sees the tag**, at boot (`tagged`) or
on `onTagAdded`, or at `registerCarriable`. The id is a per-server counter string (`"1"`, `"2"`, ...)
set as an attribute. So a client can name any carriable it can see, including one never picked up.

| State | Object | Who holds slots |
|---|---|---|
| `idle` | resting, anchored | nobody |
| `gathering` | resting where it was, anchored, not lifted | 1..min−1 carriers |
| `carried` | anchored, `CanCollide` and `CanQuery` off, CFrame driven | min..max carriers |
| `thrown` | unanchored, server-owned, in flight | nobody. The thrower and receiver are recorded |
| `dropped` | unanchored, server-owned, settling (then `idle`) | nobody |
| `delivered` | wherever the game leaves it. **Terminal** until `Carry.reset` | nobody |

| Action \ state | `idle` / `dropped` | `gathering` | `carried` | `thrown` | `delivered` |
|---|---|---|---|---|---|
| `pickUp` (join) | take slot 1. Becomes `carried` if `min == 1`, else `gathering` | take the lowest free slot. Becomes `carried` once slots ≥ `min` | join if slots < `max`, else `"full"` | `"thrown"` (only the receiver, by catching) | `"delivered"` |
| `drop` by a holder (leave) | n/a | free the slot. 0 slots: `idle` | free the slot. Slots still ≥ `min`: stays `carried`. Fewer: `belowMin` on means drop (`dropped`, every slot freed); off means `gathering` with the object set down | n/a | n/a |
| `handOff` / throw | n/a | `"notSoleHolder"` | only the sole holder of a `min == 1` object. Within `handOffRange`: slot swap. Within `throwRange` and `throwable`: `thrown` | n/a | n/a |
| catch (automatic) | n/a | n/a | n/a | the receiver (only) within `catchRadius` before the window ends: `carried` by the receiver, `HandedOff(thrown = true)`. Otherwise `dropped`, `Dropped("missedThrow")` | n/a |
| `Carry.reset` | re-arm at the spawn or a given CFrame | release, re-arm | release, re-arm | re-arm | re-arm (`idle`) |

More rules:
- **One object per player.** `pickUp` while holding a slot anywhere is refused (`"busy"`), and so is a
  hand-off or throw to a busy receiver (`"receiverBusy"`).
- A receiver can't be a co-carrier or the giver (`"invalidReceiver"`). No duplicate slot can exist.
- The thrower's slot is freed the moment the throw starts.
- A third player can't pick up a `thrown` object. After the window it is `dropped` and pickable by
  anyone.
- **Leaving during a throw:** if the thrower leaves, nothing changes (they hold no slot). If the
  receiver leaves, the object becomes `dropped` at once and `Dropped("missedThrow")` fires with
  `by = receiver`.

### Data and replication

- **No save section** in v1.8.0. Carry state is a live, server-only fact about an Instance.
- `Delivered`'s payload (carriers, timings, the Instance) is the only integration point for a game or
  another module. It is where, for example, a later quest objective would count a delivery. Carry holds
  no quest logic and no per-player tallies.

**Replicated `extra`:** one key per object, set with `ctx.replicate.setAll(key, value)`.
- **Key:** `"carry:" .. objectId`.
- **Value:** one encoded string, decoded by `Carry/shared/Codec.luau`:
  `"<state>|<tag>|<u1>,<u2>,,<u4>|<wobbleSeed>|<fromUserId>,<toUserId>,<startedAt>"`. Empty slots are
  empty fields, and the throw part is empty unless `state == "thrown"`. A string is copied and diffed as
  one value (about 7 µs per send in the v1.8.0 bench measurements).
- **When it is sent:**
  - only on a **state change** (pick-up, join, leave, throw, catch, drop, settle, deliver, reset);
  - **never before the object's first pick-up** (a missing key reads as `idle`);
  - never per tick;
  - set to `nil` when the object stops being a carriable.
- **What it never contains:** positions. The object's own `CFrame` is the only source of truth and
  streams like any part. `tag`, ids and states are server-chosen strings, never client text.

### API

```lua
export type CarryAPI = {
  registerCarriable: (tag: string, def: CarriableDef) -> (),   -- additive to config.carriables; validates like boot config, errors naming the caller
  setDropRule: (tag: string?, rules: DropRules) -> (),         -- nil tag = global default
  pickUp: (player: Player, object: Instance) -> (boolean, string?),
  drop: (player: Player, object: Instance) -> boolean,         -- a server call; reason is always "manual"
  handOff: (player: Player, object: Instance, toPlayer: Player) -> (boolean, string?),
  releasePlayer: (player: Player, reason: string) -> (),       -- public hook: free this player's slot (any anti-cheat or game rule)
  reportHazard: (player: Player, object: Instance) -> (),      -- game-observed hazard hit (drop rule "hazard")
  reset: (object: Instance, cframe: CFrame?) -> boolean,       -- re-arm (also the only way out of "delivered")
  holders: (object: Instance) -> { Player },                   -- current carriers in slot order, no holes (frozen copy)
  isCarrying: (player: Player) -> Instance?,
  objectOf: (objectId: string) -> Instance?,
  stateOf: (object: Instance) -> CarryState?,
  useWorld: (world: World) -> (),                              -- test seam (see "The World seam")
}
export type CarryState = "idle" | "gathering" | "carried" | "thrown" | "dropped" | "delivered"
```

- Every API read is a frozen view (kit-contract convention).
- `holders` lists only players present now. A carrier who left already had their slot freed.
- Refusal reasons (`pickUp`/`handOff`): `"notCarriable"`, `"busy"`, `"full"`, `"capacity"`, `"tooFar"`,
  `"disagree"` (raw root vs accepted position), `"untrusted"` (Movement says untrusted), `"thrown"`,
  `"delivered"`, `"notSoleHolder"`, `"notThrowable"`, `"receiverBusy"`, `"invalidReceiver"`, `"noCharacter"`,
  `"off"` (flag off).

**Actions** (client → server, module-api §9; declared in `Carry/net.blink` + the server part):

| Action | Wire args | Limit | Handler |
|---|---|---|---|
| `carryPickUp` | `(objectId: string(1..16))` | `{ rate = 4, burst = 6 }` | `objectOf(id)` → `pickUp(player, object)`. An unknown id is refused |
| `carryDrop` | `(objectId: string(1..16))` | `{ rate = 4, burst = 6 }` | refused unless the player holds a slot on that object. Reason forced to `"manual"`; no client string is accepted |
| `carryHandOff` | `(objectId: string(1..16), toUserId: number)` | `{ rate = 2, burst = 4 }` | looks up the receiver among present players, then `handOff`. An unknown or absent user is refused |

API signatures take Instances. Actions take ids and do the lookup and validation. The client never
sends a reason, a position or a CFrame.

### Signals

```lua
api.signals.PickedUp(player: Player, object: Instance, slot: number)
api.signals.Dropped(object: Instance, reason: DropReason, by: Player?)  -- by: the carrier that caused it, if any
api.signals.HandedOff(object: Instance, from: Player, to: Player, thrown: boolean)
api.signals.Delivered(object: Instance, zone: Instance, carriers: { Player }, timings: {
  startedAt: number, deliveredAt: number, perCarrierSeconds: { [number]: number } })  -- keyed by UserId
api.signals.Returned(object: Instance, reason: "void" | "carrierLeft" | "reset")
export type DropReason = "belowMin" | "tilt" | "stretch" | "hardLanding" | "carrierDied" | "carrierLeft"
  | "disqualified" | "teleport" | "hazard" | "missedThrow" | "manual" | "flagOff" | "removed"
```

- `Delivered.carriers` holds the carriers at the delivery tick.
- `perCarrierSeconds` includes every player who held a slot during this arming, even one who left, keyed
  by UserId. Times come from `world.clock()` deltas. `startedAt`/`deliveredAt` are `world.clock()`
  values: only their difference means anything.

### Object motion (server-authoritative, deterministic)

On every logic tick (`sampleSeconds`), for each `carried` object:

1. **Carrier positions.** For each occupied slot, read the carrier's **accepted** position:
   - With Movement enabled (`ctx.isEnabled(Movement)` checked first), use
     `ctx.deps[Movement].lastValid(player)`, which returns `(cf?, trusted)`. If it is untrusted or nil
     and `untrustedCarrier` is on, the slot is released with `Dropped("teleport", by)` (that's the
     object's drop reason when this leaves it below `min`, otherwise only the slot frees).
   - Without Movement, use the raw root from `world.rootOf`. Carry's own clamp (step 4) is what keeps
     it honest.
2. **Implied pivots.** For each slot, `holdCF_i = rootCF_i * CF(holdOffset)` and
   `implied_i = holdCF_i * CF(-gripPoints[i])`.
3. **Target** (a pure function, `Carry/shared/Blend.luau`, `targetCF(slots, def) -> (CF, tilt, stretch)`):
   - **Position:** the mean of the occupied `implied_i` positions.
   - **Orientation, 1 carrier:** the carrier's hold orientation.
   - **Orientation, 2+ carriers:** the rotation that maps the object-local axis
     `gripPoints[last] − gripPoints[first]` (the first and last *occupied* slots in slot order) onto the
     world axis `hold_last − hold_first`, with roll chosen to keep the object's up vector closest to
     world up. This is deterministic for the same inputs, and there is no quaternion averaging to flip.
   - **`tilt`:** the angle between the target's up vector and world up.
   - **`stretch`:** `max |implied_i − targetPos|`.
4. **Clamp** (Carry's own, always on):
   - **Horizontal speed limit:** `objSpeed = slowest carrier's server WalkSpeed × clamp.speedSlack`.
     That WalkSpeed is already reduced by `applyWalkSpeed`, so the speed penalty is enforced here even if
     a client ignores its WalkSpeed.
   - **Step:** `step = objSpeed × min(dt, clamp.maxDtSeconds)`. The object moves toward the target by at
     most `step` horizontally.
   - **Vertical limits:** at most `jumpVelocity × clamp.riseSlack × dt` up and `clamp.maxFallSpeed × dt`
     down.
   - **Grip break:** after the step, if a slot's implied pivot is more than `clamp.gripBreakStuds` from
     the clamped pivot, that slot is released. The reason is `"teleport"` if that slot's raw or accepted
     position jumped more than a teleport cap this tick, else `"stretch"`.
   - **Result:** the object **never moves faster than `objSpeed`**, with or without Movement. A carrier
     who teleports loses the object, and the object stays where it was.
5. **Drop rules** run on the clamped result, **before** it becomes the new motion target. A rule that
   fires drops the object at its last good pose.
6. **Motion:** the clamped pose becomes `target`, and the previous one becomes `prev`. The `motionHz`
   writer sets `lerp(prev, target, α)`, with `α = (clock − tickAt) / sampleSeconds` clamped to 0..1.
   Writes are skipped for an object whose pose hasn't changed: a clamped pose within 0.002 studs and 1e-4 per
   rotation-matrix element of the current `target` leaves `prev`, `target`, `tickAt` and the dirty flag
   untouched, so a lerp in progress finishes at the target and then writes stop (a held-still object costs no
   CFrame writes). Delivery, the hard-landing tracking and the drop rules still run every tick.

**Worked numbers (Carry clamp)** for WalkSpeed 16 and speedFactor 1. Probe:
the design math probe (a Lune model of these formulas under the latency model in Movement's "Worked
numbers"; results inline).

| Quantity | Formula | Value |
|---|---|---|
| object horizontal speed | `WalkSpeed × 1.35` | 21.60 studs/s |
| max step per logic tick | `21.60 × min(dt, 0.5)` | 2.16 studs at dt 0.1 |
| grip break | config | 12 studs |
| legit sole carrier, 300 ms + 0.5 s freezes + hitches (200 seeds × 60 s) | probe | 0 releases, max gap 7.44 studs |
| 200-stud teleport | probe | released, object ≤ 21.60 studs/s |
| 10-stud hop | probe | not released, object glides ≤ 21.60 studs/s (never jumps) |
| sustained 1.5× with Movement off | probe | released within 5.42 s (worst of 50) |

### Pick-up, hand-off, throw, catch

Every range check uses **accepted** positions, plus agreement with the raw root:
- **With Movement:** `lastValid(player)` must be trusted, and the raw root must be within `agreeStuds`
  of it (config `agree`: it scales with the player's server WalkSpeed). Otherwise the request is
  refused with `"untrusted"` or `"disagree"`.
- **Without Movement:** the raw root. A teleport-pick-up-teleport-back can then grab the object, but
  the next logic tick's grip break releases it (`Dropped("teleport")`), and the object has moved at
  most one clamp step. It is never taken across the map.

Rules per action:
- **`pickUp`:** the distance from the accepted position to the closest point of the object's box must
  be ≤ `pickUpRadius`.
- **Adjacent hand-off:** giver and receiver within `handOffRange` of each other, and the receiver within
  `pickUpRadius` of the object. The slot is swapped in the same call.
- **Throw:**
  - The receiver must be within `throwRange`.
  - The object is unanchored, then `SetNetworkOwner(nil)`, then launched by a server-side
    `setVelocity`.
  - The velocity aims at the receiver's predicted position: the accepted position plus the velocity
    from Movement's last two accepted samples (zero without Movement). `AssemblyLinearVelocity` of a
    character is never read, because it is client-set.
  - Flight speed is `throwSpeed`, with gravity compensation for the predicted flight time.
- **Catch:** each logic tick, the receiver's accepted position must be within `catchRadius` of the
  object's server position.

### Drop rules

- **`belowMin`:** fires when a slot frees and the occupied count falls below `min`. This happens in
  the same call or event, without waiting for a tick.
- **`tiltDegrees` / `stretchStuds`:** compared against step 3's `tilt`/`stretch`, after scaling by
  `fragility` (a threshold of `rule / fragility`; fragility 0 means never).
- **`hardLandingSpeed`** (and **`hardLandingMarginStuds`**): **off by default; opt in** with a number (e.g.
  `dropRules = { hardLandingSpeed = 55 }`, the value the numbers below use). The rule is a heuristic over
  server-observed positions, and it has known limits that a game turning it on accepts:
  - **a false drop:** a jump across a ditch that lands at (or just before) a delivery zone, or just before a
    hand-off, can count as a hard landing (1–3 in 10 in the kit's sims), because a fall still in the air is
    projected straight down;
  - **missed falls:** stepped cliffs (risers under the minimum fall with narrow treads: 24–40-stud falls drop
    0–1 in 10) and a jump off the crest of a 55–62° hillside (0–6 in 10) can go uncounted, since a fall counts
    at most the carriers' own rise plus the highest single ledge under their path;
  - everything listed under "what it can't see" in the known issues.

  With it on, Carry decides each fall at its touchdown (`Carry/server/Landing.luau`, all on the server-observed pivot and accepted carrier
  positions, never on client-reported state):
  - **Top:** the last height the carriers stood at, or the apex after a rise (a jump). A lower tick with every
    carrier on the ground and none in the air (walking down stairs or a ramp) moves it down there, and so do
    two level moves in a row (walking on the flat), and so does a rise with every carrier on the ground
    (walking up: one short ray per carrier on a rising tick), so a walk down followed by a ledge or a jump,
    or a jump at the crest of a climb, is measured from the last height the carriers stood at. The pick-up
    itself is such a standing point.
  - **A fall** opens on the first logic tick lower than the top. Its **touchdown** is the first lower tick on
    which every carrier is on the ground (a ray down from its accepted root, colliding parts in its collision
    group only, finds ground within its HipHeight + half its root + 1.5 studs), once the fall has seen a
    carrier in the air (no ground within HipHeight + half its root + 4 studs), or once one observed step went
    down by at least the minimum fall (a freeze or hitch hid the whole fall). The fall is decided there and the
    next one starts at the touchdown height. That height is the ground under the carriers: their own height
    (the unclamped blend target, so the object trailing them under `clamp.maxFallSpeed` never shortens a fall)
    minus how far above standing height the ray still found them.
  - **A fall with no touchdown seen** (the ray never finds ground under a carrier, or a jump straight off the
    landing) ends on a rise of 0.5 studs, or after going no lower for 1 s. While the last ray said a carrier
    was in the air, a fall that doesn't qualify yet stays open up to 3 s instead, so a connection freeze or a
    server hitch in mid-air (a lag switch) never splits a fall. It is decided on its lowest point.
  - **It drops the object iff** all of:
    - **height:** the fall height ≥ the minimum fall, the higher of `hardLandingSpeed² / (2 × Gravity)`
      (7.7 studs at 55: the height a free fall needs to land that fast) and the current carriers' highest jump
      apex `jumpVelocity² / (2 × Gravity)` plus `hardLandingMarginStuds` (4). That is 10.4 studs for
      `JumpPower` 50, 11.2 for the default `JumpHeight` 7.2 and 13.2 for `JumpPower` 60, and a 15-stud fall
      still counts at `JumpPower` 60. `jumpVelocity` is `JumpPower` with `UseJumpPower`, else
      `√(2 × Gravity × JumpHeight)` (`shared/Jump.luau`, used by the live adapter and the Lune fake alike).
      The **fall height** is top − touchdown, but at most the carriers' own rise (top − the last height they
      stood at) plus the **highest ledge** under the first carrier's path since then: rays straight down every
      0.5 studs along the path (at most 16 per tick) find the ground profile, and a ledge is a run of drops
      each steeper than 2 in 1 (63°). A stair riser is a ledge of its own height; a cliff, a hole or a steep
      hillside is one ledge. So a jump while walking down stairs or a ramp (which falls far below its apex),
      or walking down terraces of short ledges, never counts, and no jump the carriers can make, over a ledge
      of up to `hardLandingMarginStuds`, ever counts;
    - **a fall, not walking down:** a carrier was seen in the air on a lower tick, or one observed step went
      down by at least the minimum fall. Stairs, ramps and lifts keep ground under the feet;
    - **fast:** the fall's fastest observed step was at least 20 studs/s, each step timed from the previous
      pose change, so a freeze then a catch-up reads as the average speed over the freeze, never as one huge
      tick (climbing down a ladder is in the air too, but slower);
    - **not a lift:** the part under the first carrier didn't itself move down during the fall (it is
      followed from probe to probe and re-read at the decision).
  - **Before anything else ends the carry** (a delivery, `drop`, a hand-off or throw, any release from
    `carried`), an open fall that already qualifies drops the object as `hardLanding` first. While a carrier
    is still in the air, the open fall is measured down to the ground under it (where it is about to land),
    so a fall straight into a delivery zone, or a manual drop sent just before or after the landing, is a
    hard landing, never a delivery or a `manual` drop. A hand-off or throw refused this way answers
    `"notSoleHolder"` (the giver no longer holds the object).
  - **Why not a measured impact speed:** the logic tick averages 0.1 s, and only the last 0.1 s of a 15-stud
    fall is faster than 55 studs/s, so a speed test fires or not depending on where the landing falls inside
    the tick, and a freeze can hide that part entirely. Heights don't have that problem: a late position is
    still a position the carriers really had. `hardLandingSpeed` keeps its meaning through the free-fall
    relation (the floor above).
  - **Cost:** nothing while carrying level; on a tick that goes lower, one ray per carrier plus the first
    carrier's ground profile (about two rays per stud it moved sideways, at most 16; walking down a 20-stud
    staircase costs about 70 rays in all).
  - Thrown objects can't hard-land: they either get caught or drop as `missedThrow`.
- **`carrierDied`:** `onCharacter("died")` for any holder.
- **`carrierLeft`:** the leaving carrier's slot frees, and `belowMin` decides what happens to the
  object. If that leaves it with no carriers (or `belowMin` drops it):
  - `"drop"`: it is dropped where it is;
  - `"returnToSpawn"`: it is returned to its spawn CFrame (`Dropped("carrierLeft")`, then
    `Returned("carrierLeft")`). The spawn is captured when the tag is first seen, or set by `reset`.

  Either way the object is never deleted and never duplicated.
- **`carrierDisqualified`:** see "Carry × Movement".
- **`untrustedCarrier`:** see "Object motion" step 1.
- **`hazard`:** off by default. Carry has no hazard concept: a game reports a hit with `reportHazard`,
  or wires Movement's `VolumeCrossed` to it.

### Delivery

Zones are parts tagged `deliveryTag`. Each zone's box is cached at tag time and re-read when the
server writes the zone part's CFrame. On every logic tick, each `carried` object is tested against
every cached zone:

1. **Object inside:** the object's **own server-driven box** (the CFrame Carry set, and the size cached
   at registration) is inside the zone box. This is a pure OBB-in-OBB test: all 8 corners in zone-local
   space for `"full"`, or the pivot for `"center"`. Characters, `Touched` and `GetPartBoundsInBox` play
   no part.
2. **Carriers inside:** every occupied carrier's **accepted** position is inside the zone box grown by
   `deliveryReachStuds`. With Movement, every carrier must also be **trusted**, which means no struck
   or unresolved sample.
3. **Fire once:** if both hold, the state becomes `delivered`, every slot is released, the object stays
   anchored where it is, and `Delivered(object, zone, carriers, timings)` fires **once**. The first
   zone that passes (in a stable order by zone id) wins.

`delivered` is terminal:
- `pickUp` is refused with `"delivered"`;
- no zone can fire again, so overlapping zones can't double-fire;
- only `Carry.reset(object, cframe?)` re-arms the object. The game decides whether to despawn,
  respawn or re-arm.

There is **at most one `Delivered` per object per arming**. Only `carried` objects can deliver: an
object pushed, dropped or thrown into a zone doesn't count.

### After a drop: settling, the void, collisions

- **On a drop:** Carry unanchors the object, calls `SetNetworkOwner(nil)` (allowed now that it is
  unanchored) and zeroes its velocity. **`CanCollide` stays `true` the whole time** — a dropped
  object always keeps colliding with the world (floors, walls, terrain), so it can never fall
  through geometry during a no-collide window. Fling protection instead comes from a
  **collision group**: Carry registers its own default group (`"CarryDropped"`, via
  `world.setCollisionGroup`) that collides with everything except player characters, and assigns
  every carriable to it immediately on drop (no delay). A game may set `collisionGroup` to its
  own group instead (e.g. to also exclude NPCs); Carry only ever excludes characters by default.
  - **Side effect on characters:** for `"CarryDropped"` to exclude characters, the live adapter
    registers a second group, `"CarryCharacters"`, and moves every character part that is still in
    `"Default"` into it (parts a game already put in its own group are left alone). Collision rules
    a game wrote against `"Default"` (e.g. `"Default"` × `"Ghost"` not collidable) then no longer
    apply to players: write them against `"CarryCharacters"` too, or put characters in your own
    group and set `collisionGroup` to a group that doesn't collide with it.
  - **`dropNoCollideSeconds`** (deprecated as the default path, kept as an opt-in escape hatch
    for a game that can't register collision groups): when set, Carry additionally sets
    `CanCollide = false` for that many seconds on top of the collision group. Document the known
    risk if used alone without a collision group: the object can fall through thin floors during
    that window. **The shipped default is `dropNoCollideSeconds = nil`** (collision-group-only,
    no full no-collide window) — the old `0.5` default is removed.
- **Settling:** a `dropped` or `thrown` object whose server-simulated speed stays under
  `settle.speedStuds` for `settle.seconds` is **re-anchored** and becomes `idle`. From then on no
  character can push or fling it. A falling or flying object is server-simulated: clients can collide
  with it but never own it. A game that doesn't want that sets `collisionGroup`.
- **Kill plane (predictive):** every logic tick, for each unanchored object, Carry reads its Y and its
  server-simulated vertical velocity `vy` (`world.velocityOf`; the object is server-owned). If
  `y + min(vy, 0) × (sampleSeconds + killHitchSeconds) < killY`, the object is returned to its spawn,
  re-anchored, and `Returned(object, "void")` fires. `killY` defaults to
  `FallenPartsDestroyHeight + killMarginStuds`.
  - The look-ahead covers the next tick plus a server hitch, so a fast fall can't cross the margin
    between two checks. The margin covers the gravity term over the same look-ahead.
  - A resting object (`vy = 0`) is compared at its Y, so a floor just above `killY` never voids
    anything.
  - Probe: a bare `y < killY` check lost 11–70% of objects falling from 100–5,000 studs with one
    0.45 s hitch; the predictive check lost none, at Gravity 196.2 and 277.
- **Destroyed objects:** if game code destroys a carriable, or removes its tag, Carry forgets it.
  `Dropped("removed")` fires if it was held, and its `extra` key is cleared. Carry never recreates an
  Instance.

### Flags, leaving, rejoining

- **`PlayerRemoving`:** this also covers a stolen-session kick. It is handled in `onPlayerRemoving`
  and doesn't yield. It releases the player's slot per `carrierLeft`, or ends a throw they were
  receiving.
- **`CharacterRemoving` without `Died`** (`LoadCharacter`, the void): the slot is released as
  `"carrierLeft"`, with `by = player`.
- **Rejoining:** there is nothing to restore. The player starts empty-handed.
- **Flag turned off live:** every held, thrown or dropped object is released. Each held object is set
  down unanchored and then settles, firing `Dropped("flagOff")`. WalkSpeeds are restored, and every
  `carry:*` key is cleared. While off, every action is refused with `"off"`. **Turned back on:** state
  starts empty and objects are `idle`.

### Carry × Movement (works alone, works together)

- **Reads:** `ctx.isEnabled(Movement)` is checked before every `ctx.deps[Movement]` access, because a
  disabled optional dependency is an erroring proxy. Carry uses `active`, `lastValid` (accepted positions, the
  trusted flag) and `velocity` (throw aim), and nothing else.
- **Movement off = Movement absent:** before reading `lastValid` for a player, Carry asks
  `Movement.active(player)`. It is false while Movement's flag is off (the kill switch), with no World,
  and from the flag coming back on until that player's fresh baseline. Carry then uses the raw root and
  its own clamp, exactly as with Movement not booted, instead of reading `(nil, false)` as an untrusted
  carrier (which would drop every carried object and refuse every pick-up).
- **`dropRules.carrierDisqualified`:**
  - `"runDisqualified"` (the default): Carry subscribes to `RunDisqualified`. That only fires for a game
    that uses runs and the `disqualifyRun` response.
  - `"strike"`: Carry subscribes to `Strike` and acts only when `details.response ~= "log"`. A logged
    strike never drops an object. A game that sets a non-`log` response on `volumeSweep` should know
    that this mode then also releases a carrier who touches a hazard.
  - `"off"`: no subscription.

  Each case calls `releasePlayer(player, "disqualified")`.
- **Trust follows one rule** (Movement "Response policy"): only a non-`log` response on an integrity
  check revokes trust, and a `hazard` or `checkpoint` crossing never does. So at Movement's defaults
  (every response `log`), `untrustedCarrier` never fires because of a strike, and turning Movement on
  changes nothing about who holds what. A carrier is untrusted only while respawning or before their
  first sample.
- **`Carry.releasePlayer(player, reason)`** is the public hook. A game's own anti-cheat, or a game
  wiring Movement itself, calls it. Carry's auto-subscription is optional sugar.
- **Speed penalty:** enforced by Carry's own clamp (above). Carry never calls `Movement.setSpeedCap`,
  so it can't clobber a game's override. Movement independently caps at `max(speedCap, server
  WalkSpeed)`. That is automatically tighter while Carry has lowered WalkSpeed, and never looser than
  `speedCap`.
- Movement never requires, names or special-cases Carry (hard rule 7).
- **Specs, both ways:**
  - Carry with Movement absent: the clamp and grip break hold, the raw-root fallback works, and there
    is no erroring proxy.
  - Carry with Movement present: a carrier made untrusted by a non-`log` integrity strike is released;
    `RunDisqualified` drops the object under `"runDisqualified"`; a logged `Strike` drops nothing,
    through neither the subscription nor `untrustedCarrier`; a hazard crossing at a non-`log` response
    doesn't revoke trust, so it doesn't drop the object under `"runDisqualified"` or `"off"`.
  - Movement without Carry: unchanged.

### Client

The client part `Carry/client/init.luau` has `client = "Carry"` in `module.luau`, which
`KitClientDefinitions.spec` requires.

- **Bindings** use `StudWork.Client.Input.bind`, with `touchButton = true`, so each is a key, a gamepad
  button and an on-screen touch button at once (at least `minTouchTarget`, theme-tinted). Ids are
  `"Carry.interact"` and `"Carry.pass"`.
  - **`interact`** (E / ButtonX / touch):
    - Empty-handed, it targets the **nearest carriable** within its `pickUpRadius` of the local
      character (a cosmetic local read) and calls `carryPickUp(id)`. Its title is `Carry.pickUp`
      ("Pick up"), or `Carry.join` ("Help carry") when the object is `gathering` or `carried`.
    - Holding something, it calls `carryDrop(id)` with title `Carry.drop` ("Drop").
    - It is unbound while nothing is in range and nothing is held.
  - **`pass`** (F / ButtonY / touch): bound only while the local player is the **sole holder** of a
    `min == 1` object. It targets the nearest other present player within `throwRange` inside the
    camera's forward 90° cone, falling back to the nearest overall, and highlights that player with a
    client-only `Highlight`. It calls `carryHandOff(id, userId)` with title `Carry.pass` ("Pass").
  - The server re-validates everything. The client's choice of target is only a suggestion.
- **HUD widget:** `"Carry.status"`, `{ slot = "bottom", order = 1, module = "Carry" }`.
  - The slot is free: no kit or framework widget uses `bottom`. `topCenter` holds Economy 1, the
    framework's `Game.nextGoal` 2 and Mail 3.
  - It is a small chip shown only while carrying: `Carry.carrying` ("Carrying {name}"),
    `Carry.needMore` ("Needs {count} more"), `Carry.slots` ("{count}/{max}").
  - It follows `Camera.ViewportSize` changes, with a width cap and a floor, so it stays readable at
    667×375.
- **`strings`** (frozen keys in `module.luau`; English defaults):
  - `Carry.pickUp` "Pick up", `Carry.join` "Help carry", `Carry.drop` "Drop", `Carry.pass` "Pass";
  - `Carry.carrying` "Carrying {name}", `Carry.needMore` "Needs {count} more", `Carry.slots` "{count}/{max}";
  - `Carry.full` "Full", `Carry.tooFar` "Too far", `Carry.delivered` "Delivered!".

  Refusal toasts use `ctx.net.feedback` with `ctx.text.format(player, key)` for `full`/`tooFar`.
  Other refusals are silent.
- **Client API:**
  ```lua
  export type CarryClientAPI = {
    carrying: () -> string?,                              -- the local player's held objectId
    stateOf: (objectId: string) -> (CarryState, { number })?,  -- decoded from extra (state, carrier UserIds)
    onWobble: (fn: (objectId: string, angleDeg: number, phase: number) -> ()) -> Connection,
    setControls: (enabled: boolean) -> (),                -- bind/unbind interact + pass and show/hide the widget
  }
  ```
- **Wobble** is computed **on the client**, per render step, for carried objects the client has
  streamed in. It is a damped spring (`config.wobble`) driven by the object's observed acceleration,
  with the phase seeded by `wobbleSeed`. It is applied as a local visual offset that never replicates.
  `onWobble` fires with the computed values so a game can drive its own visuals instead (override
  level 3). Nothing is sent per tick.
- **Streaming:**
  - Carry sets `ModelStreamingMode = Atomic` on carriable Models when it first sees them, so a model
    never half-streams.
  - **Put a carriable Model's pivot at its bounding-box centre.** Carry reads a Model's pose from
    `GetBoundingBox()` (the box centre) but moves it with `PivotTo` (the pivot), so a Model whose
    pivot sits elsewhere (a `PrimaryPart` at one end, common in imported furniture) jumps by that
    offset on pick-up, reset and delivery (known issue). Parts are unaffected.
  - The client tolerates a streamed-out object: `objectOf` returns nil, wobble skips it, `carrying()`
    still returns the id, and the widget still shows.
  - Server state never depends on what a client has streamed, so only a live check covers the
    client-side behaviour.

### Guardrails

- **`remotes`:** `carryPickUp`/`carryDrop`/`carryHandOff` are declared actions with a `net.blink`. No
  raw remotes.
- **`textfilter`:** no action string reaches a sink.
  - `objectId` is looked up, and the server's own id is what's replicated.
  - `carryDrop` takes no reason.
  - `toUserId` is a `number`.
- **`strings`:** every client label goes through `UI.text` with a key above.
- **`special` / `modules`:** Carry requires only its own files, plus Movement's `module.luau` as the
  `optional` ref. Movement is reached only through `ctx.deps`.
- **`numbers`:** every number above is config. The kit fixture's numbers live in its `Tuning.luau`.

### Anti-cheat model (Carry)

**What a client controls:** its character's simulated position, its Humanoid state, and its requests
(ids only). Carry decides every outcome from server state:
- **Where the object is:** set only by the server, anchored, rate-limited by Carry's clamp.
- **Who holds it:** the server's slot table, refused or released on any violation.
- **Delivery:** the object's own server box, plus trusted accepted carrier positions.
- **Drops:** rules on the server-computed pose.

**What's caught (each with a planted case):**
- **Teleporting into a delivery zone:** no `Delivered`. The object's own box isn't in the zone (the
  clamp), and when Movement's `teleport` response is not `log`, the carrier is also untrusted.
- **Teleport-pick-up-teleport-back:**
  - with Movement at a non-`log` `teleport` response, refused (`"untrusted"`/`"disagree"`/`"tooFar"`);
  - at `log` (the default), or without Movement, released next tick by the grip break, and the object
    moves ≤ one clamp step.
- **A sole carrier teleporting with the object:** the slot is released and the object stays put.
- **Speed-hauling an object above the penalized speed:** the object can't go faster than the clamp,
  and the carrier loses it.
- **Re-delivering the same object, or delivering in overlapping zones:** one `Delivered` per arming.
- **Pushing or flinging a dropped object off the map:** it re-anchors when settled, and the kill plane
  returns it.

**What isn't caught, honestly:**
- A **sub-threshold hop** (below the teleport cap, about 14 studs) by a carrier, with no volume
  crossed. The object glides after them at clamp speed. This matches Movement's limit below.
- A client that **simulates a perfectly plausible path**. That isn't cheating Carry.

**False-positive budget:** zero false releases or drops for legitimate carriers on a 300 ms
connection with jitter (probe: 200 seeds × 60 s, max gap 7.44 of 12 studs). Multi-carrier jitter is
absorbed by `stretchStuds = 8`.

---

## Movement

### Config (`config.Movement`)

| Key | Default | Meaning |
|---|---|---|
| `flag` | none | feature flag. Turning it off then on re-baselines every player (see "Flags, leaving, rejoining") |
| `sampleHz` | `10` | samples per player per second |
| `staggerBuckets` | `6` | players are split into this many buckets by UserId, and the ticker runs at `sampleHz × staggerBuckets`, sampling one bucket per call. Same per-second cost, no 50-player spike in one frame |
| `minSampleFraction` | `0.5` | a call with `dt < minSampleFraction / sampleHz` for a player is skipped (catch-up bursts) |
| `speedCap` | `16` | studs/s, a floor. The base speed is `max(speedCap, server Humanoid.WalkSpeed)`, so game speed boosts never strike |
| `speedSlack` | `1.15` | multiplier on the base speed |
| `speedWindowSeconds` | `4` | the sliding window for the speed check |
| `lag` | `{ pingFactor = 1, jitterMarginSeconds = 0.15, minSeconds = 0.25, maxSeconds = 0.75, pingRefreshSeconds = 1 }` | `lagAllowance = clamp(ping × pingFactor + jitterMarginSeconds, minSeconds, maxSeconds)`. Ping is `world.ping` (live: `GetNetworkPing`, round trip), re-read per player every `pingRefreshSeconds` |
| `teleport` | `{ minLagSeconds = 0.6, slackStuds = 1, capStuds = nil }` | per-sample cap (below). `capStuds` replaces the formula with a literal |
| `rise` | `{ speedCap = nil, slackStuds = 1 }` | `speedCap = nil` means it is derived from the server's jump velocity |
| `arc` | `{ launchSlack = 1.1, gravitySlack = 0.15, heightSlackStuds = 1.5, graceSeconds = 0.2 }` | the jump/fall envelope (below) |
| `groundCast` | `{ lengthStuds = 12, footprintStuds = 2, groundedSlackStuds = 1.5, skipStuds = 4 }` | the downward Blockcast. Grounded means a hit within `hipHeight + rootHalfHeight + groundedSlackStuds` |
| `wallSweep` | `{ enabled = true, minStuds = 0.5, minPenetrationStuds = 0.2, edgeMarginStuds = 1, everySamples = 2 }` | the noclip check (below). `everySamples = 2` casts every other sample, from the last cast's position, which halves the wall casts (see "Budget") |
| `platform` | `{ graceSeconds = 1, ancestorDepth = 3 }` | moving-platform relative motion (below) |
| `climb` | `{ reachStuds = 3 }` | climbing is accepted only next to a `TrussPart` or a `climbable`-tagged part |
| `volumes` | `{}` | `{ [tag]: "hazard" \| "noEntry" \| "checkpoint" \| "platform" \| "climbable" }` |
| `anchor` | `{ reachStuds = 6, timeoutSeconds = 2, retries = 2 }` | server-move anchors (below) |
| `respawn` | `{ settleSamples = 2, settleStuds = 0.5, maxSettleSeconds = 3 }` | the respawn window (below): when a new character's sample that disagrees with the server's spawn placement counts as settled, and so strikes |
| `trustAfterCleanSamples` | `3` | clean samples after a strike before `lastValid` advances again |
| `response` | `"log"` | `"log" \| "strike" \| "resetPosition" \| "disqualifyRun"` |
| `responses` | `{}` | per-check overrides, `{ [CheckName]: response }`. The config form of `setResponse` |
| `maxStrikesBeforeKick` | `0` | 0 means never kick |
| `strikeDecaySeconds` | `60` | strikes older than this don't count toward a kick |
| `exemptDefaultSeconds` | `2` | `exempt`'s default window |
| `samplesKept` | `20` | per-player ring of recent samples for the console command |

### Worked numbers (frozen; Phase 1 implements these, doesn't re-derive them)

Defaults, a player with server WalkSpeed 16 and JumpPower 50 (jump velocity 50), Gravity 196.2,
ping 0.30 s round trip, dt 0.1 s. Results come from the design math probe: a Lune model of exactly these
formulas, including the cheap path's still-player skip. It sends client snapshots at 60 Hz with 0.15 s
one-way latency plus noise, delivered in order. It adds freeze-then-catch-up spikes of 0.1–0.3 s, plus
0.5 s for one in five, and 0.45 s server hitches through a copy of the framework's ticker. It also models
deaths, spawns and server moves (52 checks, 0 failed).

| Quantity | Formula | Value |
|---|---|---|
| lag allowance | `clamp(ping × 1.0 + 0.15, 0.25, 0.75)` | **0.45 s** (0.25 at ping 0, 0.75 at ping ≥ 0.6) |
| effective speed cap | `max(16, WalkSpeed) × 1.15` | **18.40 studs/s** |
| teleport lag | `max(lagAllowance, 0.6)` | **0.60 s** (0.75 at the clamp) |
| **teleport cap** (horizontal, per sample) | `effCap × (dt + teleportLag) + 1.0 + platformSpeed × teleportLag` | **13.88 studs** at dt 0.1 (16.64 at lag 0.75) |
| **speed window** (horizontal, last 4 s) | path length ≤ `effCap × (span + teleportLag) + 1.0 + platformSpeed × teleportLag` (the same floored lag as the teleport cap, never plain `lagAllowance`) | **85.64 studs per 4 s = 21.41 studs/s average** (88.40 = 22.10/s at lag 0.75). A sustained 1.5× (24 studs/s, 96 per 4 s) exceeds both |
| **descent bound** (per sample, part of the teleport check) | `dy ≥ −(vDown × T + ½ × g'' × T² + 1.0 + platformDownSpeed × T)`, `T = dt + teleportLag`, `g'' = Gravity × (1 + 0.15)`, `vDown = 0` if the previous sample was grounded, else `g'' × ((t − groundAt) + teleportLag)` | **56.28 studs** per sample from standing at dt 0.1 (308.98 after 1 s airborne). A failure is `Strike("teleport", { descent = true })` |
| **respawn envelope** (respawn window only) | `horizontal ≤ anchor.reachStuds + effCap × e`, `−(reachStuds + ½ × g'' × e²) ≤ dy ≤ reachStuds + apex allowance`, `e = min(t − refAt, teleportLag)`, measured from the server-authored position | **6 → 17.04 studs** horizontal, **+16.57 / −6 → −46.61 studs** vertical |
| **rise cap** (per sample) | `max(jumpVelocity, WalkSpeed) × 1.1 × 1.15 × (dt + teleportLag) + 1.0` | **45.27 studs** at dt 0.1 |
| arc launch speed | `vJ' = max(jumpVelocity, WalkSpeed) × 1.1 + max(0, platform vertical speed)` | 55 studs/s |
| arc gravity | `g' = Gravity × (1 − 0.15)` | 166.77 studs/s² |
| **arc envelope** (while airborne) | `maxY = y0 + H(τ') + 1.5`, `τ' = max(0, (t − firstAirborneSampleAt) − teleportLag − 0.2)`, `H = vJ'²/2g'` if `τ' ≤ vJ'/g'`, else `vJ'τ' − ½g'τ'²` | apex allowance **10.57 studs** above takeoff. Descending at gravity is legal for any duration |
| trust | `trustAfterCleanSamples` | 3 clean samples (0.3 s) after a strike |

**Why these hold (the bounds the probe checks):**
- **The speed window can't false-positive.** Replication is in order, so consecutive samples are chords
  of the true path between non-decreasing true times. Their summed length over the window is at most
  `trueSpeed × (span + Δlatency)`. The threshold covers `Δlatency ≤ teleportLag` with 15% to spare.
  It must be `teleportLag` (at least 0.6 s), not `lagAllowance` (0.25 s at low ping): the window is
  empty after a still spell (the cheap path writes nothing), after a strike and after a respawn, so the
  first moving sample *is* the window, and a 0.5 s freeze as the player starts walking puts up to
  9.6 studs in it. With plain `lagAllowance` the probe's stop-and-go walker struck in 11 of 200 seeds at
  ping 0.05; with `teleportLag`, 0.
- **The descent bound** covers a fall that began just after the previous sample and was seen across a
  freeze of up to `teleportLag`, at 15% more than server gravity, so any real fall (the probe: ledges of
  10–500 studs, jumps) passes. A teleport down through a floor is caught once it exceeds the bound.
- **The teleport cap** covers a freeze of up to `teleportLag` (0.6 s) in one sample.
- **A 1.5× hack** sustained over 4 s exceeds `1.15 × (4 + 0.75) / 4 = 1.37×`, even at the ping clamp
  (`1.15 × 4.6 / 4 = 1.32×` at the defaults).
- **The arc** lower-bounds the true time since takeoff by `(t − firstAirborne) − teleportLag − grace`,
  so a frozen view of a real jump stays under the envelope.

**Probe results** (the three confirming cases the design depends on, plus the rest):

| Case | Result |
|---|---|
| (a) 300 ms RTT + jitter (0.1–0.3 s freezes, 0.5 s spikes) + server hitches, walking, 200 seeds × 60 s | **0 strikes** |
| same, walking and jumping, at reported ping 0.30 and 0.05 s, 200 seeds × 60 s each | 0 strikes |
| low reported ping (lag clamps to 0.25) with 0.5 s freezes, walking | 0 strikes |
| stop-and-go walker (stands 4.5–6 s, walks 1–3 s) with the still-player skip, ping 0.05 and 0.30, 200 seeds × 60 s each; also on a 30 studs/s platform | 0 strikes (11 strike seeds with the window on plain `lagAllowance`) |
| walk off a 500-stud ledge (2.3 s free fall), ping 0.05 | 0 strikes (descent bound) |
| die, `RespawnTime` 5, spawn 2 studs up, walk away at once, at 300 ms and 20 ms; also a Plot-style `PivotTo` in the same frame or 0.05–1.0 s later | 0 strikes, every spawn accepted by arrival |
| walk off a 10, 20 or 60-stud ledge (fall arc) | 0 strikes |
| riding a 30 studs/s moving platform (relative motion) with jitter | 0 strikes |
| hitch catch-up burst (the nominal-`dt` reading was 85 studs/s) | 0 strikes, 4 zero-dt calls skipped |
| **(b) 10-stud teleport past a 0.5-stud hazard** | **caught by the volume sweep 50/50**. The teleport cap alone catches 0/50, by design (10 < 13.88) |
| 10-stud hop over the hazard after walking up to it | volume sweep 50/50 |
| in-place 25-stud teleport, no volume between | teleport cap 50/50 |
| **(c) sustained 1.5× speed hack**, ping 0.3 / 1.0 (lag 0.45 / 0.75) | **speed window 50/50 each**. First strike after 2.77 s mean (6.22 worst) / 3.15 s mean (3.62 worst) |
| hover across a 40-stud gap at constant height | noGround 50/50 |
| fly hack (rising 5 studs/s, drifting 12 studs/s) | riseSpeed/noGround 50/50 |
| 200-stud teleport (`responses.teleport = "strike"`) | exactly 1 strike, no storm, trusted again after 3 clean samples |
| straight-down teleport of 60, 80 or 200 studs from standing | descent bound 50/50 each (0/50 for 80 studs with the bound off) |
| **reset, then teleport 30–60 studs (or 200 down) as the new character arrives**, at 300 ms and 20 ms | **struck 50/50 in every case**: by the respawn envelope when the cheat replicates before the first sample, otherwise by the normal checks after the window ends at the spawn |
| logged teleport / logged 1.5× hack / hazard crossing at `strike` | recorded, trust kept (the trust rule, "Response policy") |
| `noEntry` crossing at `strike` / any integrity check at `strike` | trust revoked |

### Per-player state (frozen)

```lua
type PlayerState = {
  base: vector, baseAt: number,      -- comparison point for the next sample: ALWAYS the previous sample, struck or not
  accepted: CF?, acceptedAt: number, -- what lastValid returns; advances only while trusted
  trusted: boolean, cleanStreak: number,
  ring: <fixed arrays>, ringSum: number, platformSum: vector,  -- speed window, no per-sample allocation
  grounded: boolean, y0: number, airAt: number?,               -- arc state
  groundAt: number,                  -- last grounded sample's time (descent bound); strikes don't reset it
  platform: { inst: any, cf: CF, at: number, velocity: vector }?, platformLeftAt: number?,
  anchor: { target: CF, issuedAt: number, mine: boolean, retries: number, oldBase: vector }?,
  exemptUntil: number, respawning: boolean, lastCastAt: vector?, wallFrom: vector?, wallCount: number,
  spawnRefs: { { pos: vector, at: number } }?, settleCount: number, settlePrev: vector?, -- respawn window
  ping: number, pingAt: number,
  run: { id: string, startedAt: number }?, strikes: { Strike }, samples: <ring of samplesKept>,
}
```

- **A clean sample** moves `base` to it and increments `cleanStreak`. If the player is `trusted`,
  `accepted` moves there too. If not, and `cleanStreak ≥ trustAfterCleanSamples`, the player becomes
  `trusted` again and `accepted` moves.
- **A struck sample** (any failed check, whatever its response) moves `base` to it too: the re-baseline
  means strikes don't storm. It clears the speed window and re-baselines the arc (`y0`, `airAt`; not
  `groundAt`).
  - If a failure on it **revokes trust** ("Response policy": a non-`log` response on an integrity
    check), it also sets `trusted = false` and `cleanStreak = 0`, and does **not** move `accepted`.
  - Otherwise (every failure on it is `log`, or a `hazard` crossing) it counts as clean for trust:
    `accepted` follows as above.
- **An anchor clearing** (a server move landed) moves `base` and `accepted` there and sets
  `trusted = true`.
- **Before the first sample**, and while respawning, `lastValid` returns `(nil, false)`.
- **Re-baselines** (an anchor clearing, the end of the respawn window, `exempt` ending, flag on) also
  reset `groundAt` to that sample and clear `wallFrom`.

### Sampling

- **When:** `ctx.lifecycle.onTick(1 / (sampleHz × staggerBuckets))`. Each call samples one bucket
  (`userId % staggerBuckets`). Each player's `dt` comes from `world.clock()`, and zero-dt calls are
  skipped.
- **Who is skipped:** a player with no character, no root, a root outside Workspace, or a `Dead`
  humanoid. They are simply not sampled. A `respawning` player with a new character is sampled only for
  the respawn rule ("Exemptions", Respawn): no other check runs.
- **A sample** is `rootOf(player)` (position plus CF), a cached `humanoidFacts` (WalkSpeed, jump
  velocity, hip height; re-read with the ping), and the ground cast when it isn't skipped.
- **What is never read:** `AssemblyLinearVelocity` of a character, and Humanoid state as a trust
  signal.
- **Cheap path** (a design requirement):
  - A still player (horizontal move < 0.01 studs, |dy| < 0.01) **who was grounded at the previous
    sample** costs one read and a compare: no window write, no cast, no sweep. A still player in the air
    still runs the arc check (pure math, no cast), or hovering in place would be free (probe: hover
    still over a gap, `noGround` 50/50).
  - **Ground cast** is skipped only when the previous sample was grounded on a non-platform part,
    |dy| < 0.05, and the player is within `groundCast.skipStuds` (4) of the last cast's position. A hover
    hack drifting off a ledge is therefore re-cast within 4 studs. This is stricter than "skip while
    grounded and level", which would let a level hover drift forever.
  - **Wall cast** runs on every `everySamples`-th sample (default 2), from `wallFrom` (the position of
    the last wall cast, or the last re-baseline) to the sample, so the skipped sample's segment is still
    swept; it is skipped below `wallSweep.minStuds` of horizontal travel from `wallFrom`. Tradeoff: a
    noclip is caught up to one sample (0.1 s) later, and the longer chord can cut a sharper legitimate
    turn, which the parallel-face and edge-margin rules already ignore.
  - The volume sweep is analytic, against cached boxes, with a segment-box broad-phase reject: zero
    engine queries.
  - No table is allocated per sample (fixed rings, `vector` math).
  - `extra.movement` is never set before the player's first strike.

### Checks (each independently configurable, each with planted cases)

| Check (`CheckName`) | Rule | Legitimate exemption |
|---|---|---|
| **`speed`** | sliding window (Worked numbers): path length of horizontal segments off platforms, plus the net relative displacement on platforms, over the last `speedWindowSeconds` > the limit | the lag term is `teleportLag` (ping-aware, floored at 0.6 s, so an empty window survives a freeze). Base speed follows server WalkSpeed. Platforms are measured relatively |
| **`teleport`** | one sample's horizontal displacement (relative to a platform or seat if on one) > the teleport cap, **or** its drop below the descent bound (`details.descent = true`), **or** a respawn that settles away from the server's spawn placement (`details.respawn = true`) | sized for zero false positives (freezes up to 0.6 s; any gravity-consistent fall). Server moves anchor instead (below) |
| **`volumeSweep`** | the segment `base → sample` (platform-relative start if on one) intersects a cached `hazard` or `noEntry` box: an **exact analytic segment-vs-OBB slab test** (segment moved into the volume's local space, then slabs). Fires `VolumeCrossed` for **every** kind, `checkpoint` included, and a strike only for `hazard`/`noEntry`. Only a `noEntry` crossing can revoke trust ("Response policy") | none. A crossing between samples counts as passing through. A real player who walks into a hazard has really touched it: that is the hazard rule working, not a false positive (a game sets `responses.volumeSweep = "log"` if its hazards are routine) |
| **`noGround`** | airborne (no ground-cast hit within grounded distance) and `y > maxY` of the arc envelope while not rising | the envelope (Worked numbers): any jump the server's Humanoid allows, any gravity-consistent fall of any length. Verified climbing (below). Verified seat (below) |
| **`wallSweep`** | a thin ray at root height from `wallFrom` to the sample (every `everySamples`-th sample, "Cheap path"), with `RaycastParams.RespectCanCollide = true` and `RaycastParams.CollisionGroup` set to the character root's own group (`humanoidFacts().collisionGroup`), and every character excluded, so only parts the character would actually collide with count: `CanCollide = false` zones, checkpoints and carried objects, and parts in a group that doesn't collide with characters (dropped carry objects in `CarryDropped`, team doors), are never a wall. The ground cast uses the same filter. It hits a face, and a reverse ray hits a **parallel** face (dot ≤ −0.9), so a slab was crossed. The penetration is ≥ `minPenetrationStuds`, and the entry point is ≥ `edgeMarginStuds` from the entry face's edges (from `boundsOf`). Grazing, corner cuts and walking round a thin wall's end don't count | none. Client-only doors or parts must be non-colliding on the server too (a content rule; known issue) |
| **`riseSpeed`** | one sample's upward displacement > the rise cap, **or** `y > maxY` while rising | the same envelope. Platform vertical speed. Verified climbing |

### Exemptions

Humanoid states (`Seated`, `Climbing`, `PlatformStanding`) are **never** exemptions on their own. The
network owner (the client) runs the Humanoid state machine. `PlatformStanding` is the no-control
state, not "standing on a platform", and grants nothing.

- **Seats and vehicles:** a player is exempt only when `world.seatOf(player)` returns a server-side
  `Seat`/`VehicleSeat` holding a `SeatWeld` whose `Part1` is this character's root. Clients can't create
  replicating welds. While seated:
  - the root's motion is checked **relative to the seat**: `rel = rootNow − (seatNow * seatPrev:Inverse() * rootPrev)`;
  - the teleport and speed checks apply to `rel`;
  - the arc check is suspended.

  How the vehicle itself moves (often client-owned) is the game's vehicle code's business (see "What
  isn't caught").
- **Climbing:** accepted only when the humanoid claims `Climbing` **and** a ray from the root along its
  look vector, `climb.reachStuds` long, hits a `TrussPart` or a part tagged with a `climbable` volume
  tag. That costs one cast, only while climbing is claimed. While verified:
  - the arc check is suspended;
  - upward speed is capped by the rise cap;
  - speed, teleport, volume and wall checks stay live.
- **Moving platforms (relative motion, as the prompt asks):**
  - **Detection:** tag a platform with a `platform` volume tag. When the ground cast hits it (or a
    descendant, up to `platform.ancestorDepth`), Movement records the platform's server CFrame at each
    sample.
  - **Relative displacement:** `rel = rootNow − (platformNow * platformPrev:Inverse() * rootPrev)`. The
    teleport, speed and sweep checks use `rel`.
  - **Allowances:** the platform's speed times the lag goes into the per-sample and window allowances,
    because replication lag shows up as `platformSpeed × Δlatency` of apparent relative motion.
  - **Conveyors:** for an anchored tagged part, its server `AssemblyLinearVelocity` counts as surface
    velocity.
  - **After leaving:** the platform's last velocity stays allowed (horizontal speed, plus vertical in
    `vJ'`) for `platform.graceSeconds`.
  - **Client-simulated platforms:** `Movement.registerPlatformSource(fn(part, t) -> Vector3)` is
    optional and only for those. There is no "required call" any more.
- **Server moves (anchors):**
  - `Movement.teleport(player, cf)` writes the root through the World and opens an anchor with
    `mine = true`.
  - **Any other server write** to the character root's CFrame also opens an anchor, with
    `mine = false`. That covers a game's own teleport, and Plot's `character:PivotTo` on spawn.
    `world.onServerMove` is live `root:GetPropertyChangedSignal("CFrame")`, which fires for server
    script writes but not for physics replication (**verify in Studio**, see the checks list). Other
    code needs no knowledge of Movement.
  - While an anchor is open, each sample is checked against **both** bases:
    - within `anchor.reachStuds` of the target: the anchor clears and this becomes the new baseline;
    - otherwise it must pass every check against the **pre-move base** (a stale sample from before the
      move, still checked, volume sweep included, so an anchor is not a free window).
    - Neither: a normal strike.
  - **Anchor timeout** (`timeoutSeconds`): a `mine` anchor re-issues the same teleport, up to `retries`
    times. Only Movement's own teleports are ever re-issued. Then, and for any non-`mine` anchor, the
    next sample re-baselines with `Strike("teleport", { anchorTimeout = true })`.
  - `exempt(player, seconds, reason)` suspends every check for that long (a cutscene, or a launcher a
    game builds). The next sample after it re-baselines without comparing.
- **Respawn** (a respawn is not a free teleport):
  - `onCharacter("died")` or `onCharacter("removing")` sets `respawning`: no checks, and `lastValid`
    returns `(nil, false)`. This holds whatever `Players.RespawnTime` is.
  - **Every** `onCharacter("added")` (deaths, `LoadCharacter`, the void) keeps `respawning` and starts
    `spawnRefs` with the **server-authored** root position: the root read in the `added` handler, which
    is the engine's server-side spawn placement (verify in Studio, see the checks list). Each
    `onServerMove` while respawning (Plot's spawn `PivotTo`) appends its target. The client can't
    author either.
  - Each sample while respawning is tested against the **respawn envelope** of the latest
    `spawnRefs` entry (Worked numbers: `anchor.reachStuds` plus what the player could have walked or
    fallen since that position was set, with the elapsed time capped at `teleportLag` so waiting buys
    nothing):
    - **Inside:** the window ends (an *arrival*). The volume sweep runs from the server position to
      the sample (so a crossing during the window still counts), then the sample becomes `base` and
      `accepted`, trusted.
    - **Inside an earlier entry's envelope only:** a stale sample (the client hasn't received the latest
      server move yet). Keep waiting.
    - **Outside every envelope:** if it has **settled** (moved less than `settleStuds` over
      `settleSamples` consecutive samples, or `maxSettleSeconds` passed since the latest entry), fire
      `Strike("teleport", { respawn = true })` and re-baseline there (the struck-sample rule in "Per-player state"): `base` moves to the
      sample; if the response revokes trust, `accepted` is the server position and the player is
      untrusted until `trustAfterCleanSamples` clean samples; under `log` it is accepted, trusted.
      Until it settles, keep waiting.
  - A legitimate spawn arrives on its first sample (probe: 0 strikes across 1,000 respawns, including
    walking away at once and a Plot `PivotTo`). A Plot `PivotTo` after the window ended opens a normal
    anchor (below). Nothing is ever re-issued for a respawn.
  - **The exploit this closes:** reset the character, teleport as it arrives, stand still. Before this
    rule the first settled sample became trusted wherever it was; now it strikes (probe: 50/50 at
    300 ms and 20 ms, by the envelope when the cheat replicates before the first sample, otherwise by
    the normal checks after an arrival at the spawn).

### Data and replication

- **No save section.** Strikes and samples are in memory only, and reset on rejoin.
- **Rejoining mid-run:** the run is gone, and the game must restart it. `endRun` for that `runId` then
  returns `(false, {})`.
- **Replicated `extra`:** key `movement`, sent with `ctx.replicate.set` to the owning player only. The
  value is the string `"<strikeCount>|<lastReason>"`, **set only on a strike** and never before the
  first one. Raw samples never replicate.

### API

```lua
export type MovementAPI = {
  startRun: (player: Player, runId: string) -> (),
  endRun: (player: Player, runId: string) -> (boolean, { Strike }),  -- unknown/ended runId: (false, {})
  teleport: (player: Player, cframe: CFrame) -> (),
  exempt: (player: Player, seconds: number?, reason: string) -> (),
  strikes: (player: Player) -> { Strike },                            -- frozen copy, every recorded failure incl. "log"
  lastValid: (player: Player) -> (CFrame?, boolean),                  -- (accepted, trusted); nil before the first sample and while respawning
  active: (player: Player?) -> boolean,                              -- policing now: false with the flag off, no World, or (for a player) until the fresh baseline after the flag is back on
  velocity: (player: Player) -> Vector3?,                             -- from the last two accepted samples (throw aim)
  registerVolume: (tag: string, kind: VolumeKind) -> (),
  registerPlatformSource: (fn: (part: BasePart, t: number) -> Vector3) -> (),  -- optional; client-simulated platforms only
  setSpeedCap: (player: Player, studsPerSec: number?) -> (),          -- per-player floor override; nil clears
  setResponse: (check: CheckName, response: Response) -> (),
  useWorld: (world: World) -> (),                                     -- test seam
}
export type CheckName = "speed" | "teleport" | "volumeSweep" | "noGround" | "wallSweep" | "riseSpeed"
export type VolumeKind = "hazard" | "noEntry" | "checkpoint" | "platform" | "climbable"
export type Response = "log" | "strike" | "resetPosition" | "disqualifyRun"
export type Strike = { reason: CheckName, at: number, response: Response, details: { [string]: any } }
```

```lua
api.signals.Strike(player: Player, reason: CheckName, details: { [string]: any })  -- details.response always set
api.signals.RunDisqualified(player: Player, runId: string, reason: CheckName | "left")
api.signals.VolumeCrossed(player: Player, kind: VolumeKind, volume: Instance)       -- every crossing, inferred between samples too
```

- `startRun`/`endRun` are optional. A game without runs never calls them, and every check still runs.
- If a player leaves with an open run, `RunDisqualified(player, runId, "left")` fires from
  `onPlayerRemoving`. It is fired synchronously and doesn't yield.

### Response policy

Every failure is recorded in `strikes()` with its `response`, and fires `Strike`. Then:

| Response | Records | Counts for `endRun.eligible` | Counts toward a kick | Revokes trust | Extra effect |
|---|---|---|---|---|---|
| `log` (default) | yes | **no** | **no** | **never** | none |
| `strike` | yes | yes | yes | integrity checks only (below) | none |
| `resetPosition` | yes | yes | yes | integrity checks only | `teleport(player, accepted)`, which opens a `mine` anchor |
| `disqualifyRun` | yes | yes | yes | integrity checks only | ends the open run's eligibility. `RunDisqualified` fires once per run |

**The trust rule (one rule, used everywhere):** a failure revokes trust (`trusted = false`, so
`lastValid` is untrusted until `trustAfterCleanSamples` clean samples) **only** when the check's
configured response is `strike`, `resetPosition` or `disqualifyRun`, **and** the check is an integrity
check: `teleport` (including descent and respawn), `speed`, `wallSweep`, `noGround`, `riseSpeed`, or a
`volumeSweep` crossing of a **`noEntry`** volume. A `log` response never revokes trust. A `hazard` or
`checkpoint` crossing never revokes trust on its own, whatever the response: it is a gameplay signal,
not a position-integrity fault. A `noEntry` crossing is treated as an integrity fault because those
volumes mark places a legitimate player can't reach (out of bounds, behind walls), so a position there
shouldn't count for pick-up or delivery.

So at the defaults (every response `log`), turning Movement on changes no gameplay: nothing is
disqualified, kicked, reset or made untrusted. Its only effects are records, signals, and Carry using
accepted positions instead of raw roots.

- `endRun.eligible` means no non-`log` entry since `startRun`.
- The kick fires when non-`log` entries within `strikeDecaySeconds` reach `maxStrikesBeforeKick` (if it
  isn't 0). It calls `world.kick(player, ctx.text.format(player, "Movement.kicked"))`.

### Console

`movement samples <userId> [n]` prints that player's last `n` (≤ `samplesKept`) samples: position,
dt, displacement, caps, grounded, check results. `player` is nil from the command bar, so the target
is a userId argument. It is registered only when `ctx.isStudio`.

### Flags, leaving, rejoining

- **Flag off:** no sampling, no strikes. `lastValid` returns `(nil, false)` and `active()` returns
  `false` (so Carry falls back to its own clamp only).
- **Flag on again:** every player's next sample becomes a fresh, trusted baseline (`base`,
  `accepted`, `groundAt`), so nobody is compared against a stale position. There is no server position
  to compare it with, and turning a flag on is a server action, so no envelope applies. A player who
  is mid-respawn keeps the respawn rule.
- **Leaving:** state is dropped in `onPlayerRemoving`, and an open run fires `RunDisqualified("left")`.
- **Rejoining:** a fresh baseline, no strikes.

### Guardrails

- **`remotes`:** Movement has no client action and no client part (`client = nil`).
- **`special` / `modules`:** Movement requires nothing outside its own folder.
- **`numbers`:** every threshold is config.
- **`strings`:** `Movement.kicked` ("Removed for unusual movement") is used server-side through
  `ctx.text`.

### Anti-cheat model

**What's caught (each with planted sims; numbers from the probe):**
- **A 10-stud teleport past a hazard:** caught **by the volume sweep** (exact, analytic). It is *not*
  caught by the per-sample teleport cap, which must stay at 13.88 studs to give zero false positives at
  300 ms. A teleport **with no volume between** is caught by the teleport cap once it exceeds the cap
  (planted: 25 studs).
- **Floating or hovering over a gap** longer than a legal jump: `noGround` (the arc envelope). It is
  detected about 1.3–1.5 s into the hover.
- **Speed-walking or speed hacks:** the 4 s window. A sustained 1.5× is caught within about 2–6.5 s,
  even with ping inflated to the clamp.
- **Noclip through a wall:** `wallSweep` (slab crossed, not grazed).
- **Fly hacks:** `riseSpeed`/`noGround`. That includes a `PlatformStand` or forged-`Climbing` fly, since
  no Humanoid state exempts anything.
- **Entering a `noEntry` volume, or teleporting past a checkpoint:** the volume sweep. A checkpoint
  counts as passed through `VolumeCrossed`.
- **Teleporting down through a floor:** the descent bound, once the drop exceeds it (56 studs per
  sample from standing at the defaults).
- **A respawn used as a teleport** (reset, move as the new character arrives): the respawn envelope,
  or the normal checks after the window ends at the spawn.

**What isn't caught, honestly:**
- **Sub-sample teleport-and-back** (out and back within 0.1 s): it is never sampled. Raising `sampleHz`
  narrows the window at proportional cost.
- **A hop shorter than the teleport cap** (about 14 studs at 300 ms) **that crosses no tagged volume**.
  Repeated hops add up in the speed window and get caught. A single one doesn't. The same holds for a
  hop inside the respawn envelope (at most about 17 studs, once per spawn).
- **A drop shorter than the descent bound** (about 56 studs per sample from standing, more across a
  server hitch or while already falling) **that crosses no tagged volume**, such as a short drop through
  a floor. `wallSweep` is horizontal, so it doesn't see vertical noclip.
- **Short speed bursts** (shorter than the window) below the teleport cap.
- **A speed hack that only runs in circles** at under 1.37×.
- **A client-owned vehicle's own motion:** the seat-relative check covers the rider, not the vehicle.
  That is the game's vehicle code.
- **Inflating ping:** it buys at most the 0.75 s clamp. Even then a sustained 1.5× is still caught.

**False-positive budget:** zero strikes for a real player on a 300 ms connection with jitter (freezes
up to 0.5 s), jumping, falling off ledges of any height, riding tagged moving platforms, respawning
(any `RespawnTime`), being moved by any server code (Plot `PivotTo`, `Movement.teleport`), and sitting
in real seats. The probe confirms the math, and planted sims confirm the built code.

The remaining risks are:
- **Content:**
  - client-only doors;
  - untagged moving platforms or conveyors faster than the slack;
  - low-gravity zones or custom forces (games `exempt` those, or raise `arc.gravitySlack`).
- **Engine facts to verify in Studio** (see the checks list).

---

## Budget (both modules)

**Target (one shared headroom, not a budget per module):** the KITS-ALL bench variant with **both**
Carry and Movement on must cost **≤ 1.128 ms per bench tick**. That is v1.7.0's KITS-ALL reference of
0.94 ms plus 20%, the same rule as every other kit (CLAUDE.md "Definition of done"). One bench tick is
`h:tick(1)`, one second of game time.

The number is **Luau ms measured by `tools/bench`, plus the engine calls the fake World counts** (casts
and CFrame writes) **× their per-call cost measured once in Studio**: `os.clock` around 1,000
`Raycast`, `Blockcast` and anchored `CFrame` writes in the Studio block. The prompt says "raycasts
counted", so they are.

**Workload sizes:**
- **KITS-ALL+carry:** 50 fake players, all Movement-sampled at 10 Hz and walking scripted paths, with
  one jump in five. 12 objects × 4 carriers (48 carriers, the most 50 players allow), objects carried
  continuously. One scripted cheat every ~50 ticks. **This variant carries the 1.128 ms target.**
- **CARRY-20x4:** 80 fake players, 20 objects × 4 carriers (the prompt's literal Carry budget),
  Movement off. Reported as Carry's **marginal** cost over the same 80-player variant without Carry.
  It must fit the same 0.188 ms shared headroom.
- **MOVEMENT-50:** 50 players at 10 Hz, Carry off. Reported for diagnosis.

**Design requirements for the cheap path** (not optional):
- analytic sweeps (no engine volume queries);
- no per-sample or per-object allocation (fixed rings, `vector`, cached boxes);
- the cast-skip rules above;
- still players early-exit;
- staggering (`staggerBuckets`);
- motion writes only for objects that moved, at `motionHz`;
- **no `extra` key set before the first change** (`carry:<id>` before the first pick-up,
  `movement` before the first strike). Two modules with `extra` and zero calls measured about 0.1 ms in
  v1.8.0, because every flush re-snapshots each module's extra.

**Estimate, not a verified number:** a pure-Luau model of this cheap path (the design cost probe) gives:
- With every player walking: about **0.16 ms** for Movement (50 × 10 Hz), against 0.52–0.56 ms for a
  naive sample that allocates and runs every check.
- Carry's 12×4 tick plus 30 Hz motion adds about **0.011 ms**.
- Engine calls per bench tick, **with the shipped default `wallSweep.everySamples = 2`**: about 167
  ground casts, **250** wall casts (500 at `everySamples = 1`) and 360 CFrame writes, so about 417
  casts and 360 writes. They are unpriced in that probe.

**What that means for the 1.128 ms target:** the Luau part (about 0.17 ms) already uses most of the
0.188 ms headroom, leaving about 0.017 ms for the engine calls. That holds only if a cast and a write
cost about 0.02 µs each, far below what a `Raycast` typically costs. So the target is **likely missed
by the engine-call price** even with `everySamples = 2`, and Phase 1 must measure that price in Studio
first (Engine facts, item 2), before tuning. Shipping `everySamples = 2` now removes the largest single
term (250 casts) without weakening the check ("Cheap path"). **If the built code still misses
1.128 ms after two honest optimization passes, that is a known issue**, with these knobs named, in
this order:
- `wallSweep.everySamples` (3 cuts the wall casts to about 167);
- `groundCast.skipStuds`;
- `motionHz` (20 cuts the writes to 240);
- `sampleHz`.

## Overrides

Both modules follow the five override levels (`docs/philosophy.md` §2, module-api.md §11):
1. **Defaults:** list `Carry`/`Movement` in `GameConfig.modules`. Carry does nothing until a
   carriable tag is configured. Movement validates at the defaults with `response = "log"`, which is
   invisible until a game raises it.
2. **Config:** every table above.
3. **Replace a piece:**
   - a game's own wobble, through `onWobble` with `wobble.enabled = false`;
   - its own disqualification policy, through `releasePlayer`;
   - a source for client-simulated platforms, through `registerPlatformSource`;
   - per-check responses.
4. **Switch off:** leave either module out. Each works without the other.
5. **Write your own:** both modules use only the public API plus a kit-owned test seam. A
   third-party module could do the same (hard rule 7).

## Engine facts Phase 1 must verify in Studio

These go into the Studio block, with a screenshot or log line each:
1. `root:GetPropertyChangedSignal("CFrame")` fires on the server for a server `PivotTo` or `CFrame`
   write, and **not** for the owner's physics replication. If it does fire for replication, the
   fallback is: games' teleports, including a spawn `PivotTo` after `CharacterAdded`, must call
   `Movement.teleport`/`exempt`, or they strike once (`teleport`, `respawn = true` inside the respawn
   window) and re-baseline. That becomes a known-issue entry.
2. The per-call cost of `Raycast`, `Blockcast` and an anchored `CFrame` write (1,000 each, `os.clock`),
   fed into the bench pricing.
3. A `SeatWeld` is server-created and `Part1` is the root, for both `Seat` and `VehicleSeat`.
4. `GetNetworkPing` reflects Studio's network simulator at 300 ms.
5. An anchored carried object driven at `motionHz = 30` looks smooth to a second client at 300 ms
   (screenshot or recording; the hand check on real phones stays a user check).
6. In a `CharacterAdded` handler on the server, the character's root is already at the engine's spawn
   placement (the respawn rule's first server-authored position). If Studio shows the engine moves it
   later, the fallback is to read that position on the first `Heartbeat` after `added` instead. The
   client can't have replicated a move by then, because it hasn't received the character yet.
