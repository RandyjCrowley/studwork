# Pending edits to shared/off-limits files: `carry` kit (v1.8.0)

**Status: final.** Complete as of the round's last commit on `feature/v1.8-carry`. Every builder
subsection below is filled in or says "none"; the orchestrator added the final-review and
footprint sections at the end of the round.

The designer and the design fixer wrote this file, for round `v1.8-carry`.
- **Who writes:** each builder appends only to its own lettered subsection under each file's heading,
  so parallel builder commits don't conflict on the same hunk.
- **Who applies:** the user's merge session applies every snippet below by hand after merging
  `feature/v1.8-carry`. **No agent in this round applies anything in this file**, except the two
  tool/branch edits listed under "Edits made on the branch (not pending)".

Merge order and owners:
- **A** = foundation builder
- **B** = Carry builder
- **C** = Movement builder
- **D** = sims/bench builder

A builder with nothing to add under a heading leaves its subsection empty (don't delete the heading).

---

## Footprint outside the kit (audit at the round's end)

**Framework files touched: none.** `git diff --stat fd651d7..feature/v1.8-carry -- packages/framework
packages/ui` is empty. No off-limits doc (CHANGELOG, README, VERSION, module-api/reference,
kit-contract, guardrails, known-issues, decisions, manual-qa) and no CI or root project file changed.

Every file outside `packages/kits/carry/`, `docs/framework/kits/carry.md`, `docs/pending/carry.md` and
`examples/carry/` that the branch changes:

| File | Change | Why |
|---|---|---|
| `templates/new-game/default.project.json` | +27, `tools/sync-projects` output | lint runs `sync-projects --check`; the tool maps every kit module into every project |
| `examples/sandbox/default.project.json`, `examples/sandbox/foundation-only.project.json` | +27 each, tool output | same |
| `examples/overrides/ov-{a,b,c,d,e,f}/default.project.json` | +27 each, tool output | same |
| `examples/modules/session-leaderboard/tests/fixture-game/default.project.json` | +27, tool output | same |
| `tools/lune/NewGame.spec.luau` | 1 line: module count 15 -> 17 | the manifest appends discovered kit modules |
| `tools/lune/bench/replication.luau` | +25/-2, additive | registers the kit's bench variants (see "Bench variants") |
| `tools/lune/bench/CarryVariant.luau` | new file | the kit's bench variants |

At merge: re-run `tools/sync-projects` instead of resolving the project JSON by hand, and set the
`NewGame.spec.luau` count to the number of kit modules present after both kits land.

---

## Dogfood fixes (orchestrator, docs-only, not pending — `carry.md` is the kit's own doc)

Dogfood iteration 1 found `docs/framework/kits/carry.md` had no practical walk-through for
wiring a carriable, a delivery zone, or a timed Movement run, and that the `decisions.md`
snippet above still described the pre-H7-fix "CanCollide returns after a short grace" drop
behavior instead of the current collision-group default. Both fixed directly in `carry.md` (new
"Quickstart" section after the doc-URL list) and in this file's `decisions.md` snippet above.
Neither needed a pending entry since `carry.md` isn't off-limits.

Dogfood iteration 2 (confirming the fix; max 2 iterations per the studwork-round skill, stopped
here) got a working game but found 8 more stuck points, 6 new. Fixed directly in the quickstart
without a 3rd dogfood round (factual, unambiguous corrections, each verified against the actual
dogfood transcript): the `--modules` `tools/new-project` bug (see the `--modules` section below
— a real tooling bug, not a doc gap, documented there for whoever adds `--modules` support);
corrected file paths (`src/shared/Config/init.luau`, `src/server/Boot.spec.luau`, not the
generic names originally written); named the actual signals (`Carry.signals.PickedUp`/
`Delivered`) and the per-carrier `startRun`/`endRun` pattern with `endRun`'s real return shape;
added the `RunDisqualified` handling note (a disqualified carrier never reaches `Delivered`);
corrected the "small amount of the World type" claim to the real ~24-member list, with the
`onCharacter("added", ...)` contract spelled out (the single most common stuck point writing a
fake `World`) and the `players()` array-vs-map note; added the harness replicated-data read
path. These are "fixed, not re-dogfooded a third time" per the skill's rule — the final report
lists them as such.

---

## Edits made on the branch (not pending): tool output and non-off-limits specs

- **`tools/sync-projects` output** (`templates/new-game/default.project.json`, `examples/sandbox/*.project.json`,
  `examples/overrides/ov-*/default.project.json`,
  `examples/modules/session-leaderboard/tests/fixture-game/default.project.json`,
  `examples/carry/default.project.json`).
  - **Why:** `tools/lint` runs `sync-projects --check`, and the tool maps every kit module into every
    project. So once `packages/kits/carry/{Carry,Movement}/` exist, lint and the pre-commit hook fail
    until the tool has run.
  - **The rule** (this round's rule for parallel rounds): tool-generated edits to off-limits files are
    allowed when lint requires them. That means tool output only, never hand edits, a re-run at merge,
    and a listing here.
  - **Who:** the **foundation builder (A)** runs `tools/sync-projects` for real, in its own worktree, in
    the same commit that adds the module folders. Nobody hand-edits those JSON files. **The
    orchestrator re-runs `tools/sync-projects` at the final merge** (and after merging the `quests`
    round, if both land): a conflict in those files is resolved by re-running the tool, never by hand.
  - **A lists in its report** the exact files the tool touched.
- **`tools/lune/NewGame.spec.luau`:** `expect(#Modules.ORDER).toBe(15)` becomes `17`. The manifest
  appends discovered kit modules that `KitModules.ORDER` doesn't list ("kit modules the template
  doesn't list yet go last, alphabetically"), so Carry and Movement make it 17. This spec is **not**
  off-limits: the foundation builder (A) edits it directly on its branch, in the module-folder
  commit.
  - If the `quests` round also adds modules, the merge reconciles the number: the count of every kit
    module present.
- **No change** to `tools/lune/KitModules.luau` (`ORDER`): extras sort last automatically, and Carry
  and Movement have no ordering constraint. There is **no** `KitModules.spec.luau`; an earlier draft of
  this file wrongly cited one.

---

## `CHANGELOG.md`

### A (foundation)

```markdown
### Added
- `carry` kit (`packages/kits/carry/`, see [carry.md](docs/framework/kits/carry.md)):
  - **Carry:** objects carried by one or more players. The server drives them (anchored, CFrame
    interpolated on Heartbeat, rate-clamped, `CanQuery` off while carried). Includes hand-off,
    throw-and-catch, join/leave, drop rules (hard-landing drops are **opt-in**, off by default: when a
    game sets `hardLandingSpeed`, each fall is decided at its touchdown, at least the carriers' jump apex
    plus `hardLandingMarginStuds` high, with known limits listed in known-issues), delivery zones (`Delivered` fires
    once per arming, with the carrier list and timings), a kill plane, the `carryPickUp` / `carryDrop` /
    `carryHandOff` actions, and touch, keyboard and gamepad bindings. Dropped objects go to a `CarryDropped`
    collision group that excludes characters; `CanCollide` is never turned off by default.
  - **Movement:** a server-side movement validator. It checks a sliding-window speed cap with
    ping-aware lag allowance, a per-sample teleport cap, an analytic path sweep against tagged
    `hazard`/`noEntry`/`checkpoint` volumes, a ground cast with a jump/fall envelope, a wall sweep and
    a rise cap. Its casts respect `CanCollide` and the character's own collision group, so zones,
    checkpoints and carried or dropped objects are never a wall. Platform- and seat-relative motion,
    server-move anchors and respawn settling cover legitimate moves. Also `startRun`/`endRun`,
    `teleport`/`exempt`, `active`, and a `log` (default) / `strike` / `resetPosition` /
    `disqualifyRun` policy. A Studio-only `movement samples` console command shows a player's live
    samples.
  - Both are additive kit modules, and each works without the other: with Movement absent or its
    flag off, Carry falls back to its own clamp. `useWorld` is a documented kit-level test seam.
  - Known issue: at the default cadence the two modules cost more than the 20% tick budget (see
    known-issues).
```

### B (Carry builder)

None: folded into A's entry above (the entry describes the final behaviour; every builder and fixer
change is to a feature new in this release, so there is no "Changed"/"Fixed" line).

### C (Movement builder)

None: folded into A's entry.

### D (sims/bench builder)

None.

---

## `docs/decisions.md`

### A (foundation)

```markdown
## Carry drives carried objects anchored, by CFrame, interpolated on the shared ticker (v1.8.0)

**Decision:** while carried, an object is anchored with `CanCollide` off.
- The server computes a clamped target from the carriers' validated positions at 10 Hz.
- It writes the object's CFrame (`PivotTo` for models) at `motionHz` (default 30) from
  `ctx.lifecycle.onTick`, which runs on Heartbeat, interpolating between the last two targets.
- On a drop the object is unanchored, then `SetNetworkOwner(nil)`. `CanCollide` stays `true` the
  whole time (never disabled by default) — fling protection comes from a collision group
  (`"CarryDropped"`, excludes characters only) assigned immediately, not a no-collide window.
  Once settled, the object is re-anchored.
- `AlignPosition`/`AlignOrientation` are not used.

**Why:**
- **Ownership:** anchored parts are always server-owned, so a client can never own a carried object.
  `SetNetworkOwner` errors on anchored parts, so it is called only after unanchoring.
- **No free fall:** an unanchored, non-colliding part driven at 10 Hz free-falls between writes (about
  1 stud per 0.1 s, and through the floor on a server hitch), and clients see 10 Hz steps.
  Interpolated writes on an anchored part do neither.
- **Determinism:** Align* constraints need a simulated body, which costs a physics step per object,
  and their settle time is non-deterministic. CFrame driving keeps the blend and clamp pure functions
  that the sims assert on.
- **Re-anchoring settled objects** stops characters from pushing or flinging them. A kill plane above
  `FallenPartsDestroyHeight` returns any object that falls out, so the engine never destroys it.

Docs relied on:
- network ownership: https://create.roblox.com/docs/physics/network-ownership
- AlignPosition: https://create.roblox.com/docs/physics/constraints/align-position
- AlignOrientation: https://create.roblox.com/docs/physics/constraints/align-orientation
- RunService: https://create.roblox.com/docs/reference/engine/classes/RunService
- Workspace (`FallenPartsDestroyHeight`): https://create.roblox.com/docs/reference/engine/classes/Workspace
- streaming: https://create.roblox.com/docs/workspace/streaming

## Movement derives every check from server-observed positions and its own clock; no Humanoid state is an exemption (v1.8.0)

**Decision:**
- **Positions only:** every check derives from the character root positions the server observes. It
  never reads `AssemblyLinearVelocity` (client-set) and never treats a Humanoid state (`Seated`,
  `Climbing`, `PlatformStanding`) as trusted, because the network owner runs the state machine.
- **Clock:** time comes from the module's own monotonic clock (`os.clock`), not the ticker's nominal
  `dt`.
- **Speed:** a 4 s sliding window with a ping-aware lag allowance,
  `clamp(ping + 0.15, 0.25, 0.75)` seconds, floored at 0.6 s for the window and the teleport cap alike
  (an empty window must survive a 0.5 s freeze).
- **Teleports:** a per-sample cap sized for zero false positives, plus a descent bound derived from
  server gravity. A short teleport past a tagged volume is caught by an exact analytic path sweep.
- **Respawns:** the new character is compared with the server's spawn placement (or a later server
  move), so a respawn is not a free teleport.
- **Trust:** only a non-`log` response on an integrity check revokes trust. A `hazard`/`checkpoint`
  crossing never does, so at the defaults (`log`) Movement changes no gameplay.
- **Seats:** exempt only with a server-side `SeatWeld` to the root, then checked relative to the seat.
- **Climbing:** accepted only next to a `TrussPart` or a tagged climbable part.
- **Platforms:** measured relative to the tagged platform's server CFrame.
- **Server moves:** any server write to the root's CFrame opens an anchor, so other code (for example
  Plot's spawn `PivotTo`) needs no knowledge of Movement.

**Why:**
- A client owns its character's physics and Humanoid state. Only the replicated position is
  independent of what the client claims.
- The ticker's `dt` is nominal and bursts after a hitch.
- A per-sample speed rule without a lag term strikes real players on 300 ms connections, while the
  window absorbs a freeze-then-catch-up and still catches a sustained 1.5x.
- The design math was probed: 0 strikes for legitimate play with 0.5 s jitter spikes, and every
  planted cheat caught (`docs/framework/kits/carry.md` "Worked numbers").

Docs relied on:
- network ownership: https://create.roblox.com/docs/physics/network-ownership
- Humanoid: https://create.roblox.com/docs/reference/engine/classes/Humanoid
- `HumanoidStateType`: https://create.roblox.com/docs/reference/engine/enums/HumanoidStateType
- Seat: https://create.roblox.com/docs/reference/engine/classes/Seat
- `Player:GetNetworkPing`: https://create.roblox.com/docs/reference/engine/classes/Player
- raycasting: https://create.roblox.com/docs/workspace/raycasting
- WorldRoot (Blockcast): https://create.roblox.com/docs/reference/engine/classes/WorldRoot
- collisions (collision groups): https://create.roblox.com/docs/workspace/collisions

## The carry kit reads the world through a kit-owned `World` adapter (a test seam), not a framework change (v1.8.0)

**Decision:**
- **What the adapter covers:** Carry and Movement read characters, casts, tags, seats, ping and the
  clock only through a `World` object.
- **Live adapter:** the module's `shared/World.luau`. It fetches services lazily, under `pcall`,
  never at load or in `init`.
- **Fake adapter:** `packages/kits/carry/tests/FakeWorld.luau`, scriptable, and counting the engine
  calls it receives.
- **Installing a fake:** specs call `Carry.useWorld` / `Movement.useWorld`, a documented test seam.
- **No harness change:** `Services.ALLOWED` and the harness are unchanged.

**Why:**
- **The harness has no world:** its Workspace is empty and it can't provide `CollectionService` or
  `RunService`, so the anti-cheat sims need injected geometry, latency and characters.
- **Nothing is special:** a kit-owned seam keeps the framework untouched, and any third-party module
  could do the same.
- **Default boots keep working:** lazy, `pcall`-guarded service access keeps "boot every module at
  defaults" (`test-adopt`, new-game) working under the harness, where the module simply idles.
```

### B (Carry builder)

None.

### C (Movement builder)

None.

### D (sims/bench builder)

None.

### Final fixes (Studio block and final review)

```markdown
## Movement's casts use the engine's collision filter, and Carry gives characters their own group (v1.8.0)

**Decision:**
- Movement's wall sweep and ground cast set `RaycastParams.RespectCanCollide = true` and
  `RaycastParams.CollisionGroup` to the character root's own group (read on the server, refreshed
  with the ping), with every character excluded.
- Carry turns `CanQuery` off on a carried object (back on when it is put down), so a game's own
  raycasts don't hit it either.
- Dropped objects go to `"CarryDropped"`; for that group to exclude characters, the live adapter puts
  character parts still in `"Default"` into `"CarryCharacters"`.
- `Movement.active(player?)` says whether Movement is policing that player now. Carry uses the raw
  root under its own clamp while it is false (flag off), the same as with Movement absent.

**Why:**
- By default `Raycast`/`Blockcast` hit any part with `CanQuery = true`, including `CanCollide = false`
  parts, and filter by the params' group (`"Default"`), not the character's. Without the filter a wall
  sweep struck every player walking through a zone, a checkpoint or a carried object: invisible in
  Lune (the fake skipped non-colliding parts) and found live in Studio.
- A kill switch must turn a module off, not turn its sibling's trust model into "untrusted".

Docs relied on:
- raycasting: https://create.roblox.com/docs/workspace/raycasting
- RaycastParams: https://create.roblox.com/docs/reference/engine/datatypes/RaycastParams
- collisions (collision groups): https://create.roblox.com/docs/workspace/collisions
```

---

## `docs/framework/module-reference.md`

### A (foundation)

No change needed. Carry and Movement add no framework-level (`StudWork`/`ctx`) surface: only kit API,
config and replicated `extra`, documented on their kit page. Kits aren't listed individually in
module-reference.md. `useWorld` is kit API, not a framework hook.

### B / C / D

None.

---

## `docs/framework/kit-contract.md`

### A (foundation)

Add one new top-level section after "## Engagement kit", following the file's own format. **Both
modules go under "## Carry kit"**, with kit folder `Carry` (`Modules.kitFolder("Movement") == "Carry"`).

```markdown
## Carry kit

### Carry

- **api:**
  - setup: `registerCarriable(tag, def)`, `setDropRule(tag?, rules)`;
  - actions on objects: `pickUp(player, object) -> (boolean, reason?)`, `drop(player, object) -> boolean`,
    `handOff(player, object, toPlayer) -> (boolean, reason?)`, `releasePlayer(player, reason)`,
    `reportHazard(player, object)`, `reset(object, cframe?) -> boolean`;
  - reads: `holders(object) -> { Player }`, `isCarrying(player) -> Instance?`,
    `objectOf(objectId) -> Instance?`, `stateOf(object) -> CarryState?`;
  - test seam: `useWorld(world)`.
- **actions (client):** `carryPickUp(objectId)`, `carryDrop(objectId)`, `carryHandOff(objectId, toUserId)`.
- **signals:** `PickedUp(player, object, slot)`, `Dropped(object, reason, by?)`, `HandedOff(object,
  from, to, thrown)`, `Delivered(object, zone, carriers, timings)`, `Returned(object, reason)`.
- **Uses:** Movement (optional): `active`, `lastValid`, `velocity`, `signals.RunDisqualified`/`Strike`.
  Without Movement, or while `Movement.active(player)` is false (its flag off), it uses the raw root
  under Carry's own clamp.
- **Replicated `extra`:** `carry:<objectId>` (`setAll`, one encoded string per object, set on state
  changes only). **Save section:** none.

### Movement

- **api:**
  - runs: `startRun(player, runId)`, `endRun(player, runId) -> (eligible, strikes)`;
  - server moves: `teleport(player, cframe)`, `exempt(player, seconds?, reason)`;
  - reads: `strikes(player) -> { Strike }`, `lastValid(player) -> (CFrame?, trusted)`,
    `active(player?) -> boolean` (policing now: false with the flag off), `velocity(player) -> Vector3?`;
  - setup: `registerVolume(tag, kind)`, `registerPlatformSource(fn)`, `setSpeedCap(player, studsPerSec?)`,
    `setResponse(check, response)`;
  - test seam: `useWorld(world)`.
- **signals:** `Strike(player, reason, details)`, `RunDisqualified(player, runId, reason)`,
  `VolumeCrossed(player, kind, volume)`.
- **Uses:** nothing (a general-purpose validator).
- **Replicated `extra`:** `movement` (`set`, owning player only, `"<strikeCount>|<lastReason>"`, set on
  the first strike and later). **Save section:** none.
```

### B (Carry builder)

None: the entry above matches the built `Carry/shared/Types.luau` (checked at the round's end).

### C (Movement builder)

None: the entry above matches the built `Movement/shared/Types.luau`, including `active` (added by
the final fix pass).

### D (sims/bench builder)

None.

---

## `docs/framework/guardrails.md`

### A (foundation)

No new lint rule. Carry and Movement are expected to pass `modules`, `remotes`, `special`, `numbers`,
`strings` and `textfilter` unmodified (carry.md, each module's "Guardrails").

### B / C / D

None. One guardrail fired during the build and was respected, not changed: `[remotes] Instance.new
with a dynamic class name` refused the fixture's `Instance.new(props.ClassName)`; the fixture now
picks the class from a fixed list.

---

## `docs/framework/kits/README.md` (if it exists)

### A (foundation)

If the file exists and is an index of kit pages, append:

```markdown
- [Carry](carry.md): objects carried by one or more players (hand-off, throw and catch, drop rules,
  delivery zones), and Movement, a server-side movement validator.
```

### B / C / D

None.

---

## `docs/known-issues.md`

### A (foundation)

```markdown
### Movement can't see a teleport-and-back within one sample (v1.8.0)

Movement samples at `sampleHz` (10 Hz by default). A teleport out and back within 0.1 s leaves no
trace in the samples. Raising `sampleHz` narrows that window, at a proportional tick cost.

### Short hops below Movement's teleport cap are caught only if they cross a tagged volume (v1.8.0)

The per-sample teleport cap is sized so a real player on a 300 ms connection with jitter never
strikes. That is about 14 studs per sample at the defaults (`docs/framework/kits/carry.md` "Worked
numbers"). A single shorter hop is caught only if it crosses a `hazard`, `noEntry` or `checkpoint`
volume (the path sweep is exact). Repeated hops add up in the 4 s speed window and are caught there.
Tag the volumes that matter.

The same holds for a single hop inside the respawn envelope (at most about 17 studs, once per spawn),
and for a drop shorter than the descent bound (about 56 studs per sample from standing, more across a
server hitch or while already falling), such as a short drop through a floor: the wall sweep is
horizontal, so it doesn't see vertical noclip.

### Movement content rules: server-side doors, tagged platforms, gravity (v1.8.0)

- **Doors:** a door opened only on the client is still solid on the server, so walking through it is
  a `wallSweep` strike. Open doors on the server, or make them non-colliding there.
- **Platforms and conveyors:** a moving platform or conveyor must carry a `platform` volume tag to be
  measured relatively. A client-simulated platform also needs `Movement.registerPlatformSource`.
- **Gravity and forces:** low-gravity zones and custom forces (jump pads, knockback) must call
  `Movement.exempt` or raise `arc.gravitySlack`.
```

### B (Carry builder)

None beyond the final-review entries below (B's model-pivot and wobble notes are folded in there).

### C (Movement builder)

None. The Studio block did not show `GetPropertyChangedSignal("CFrame")` firing for physics
replication (a client-side teleport still struck; a server write opened an anchor), so the fallback
entry isn't needed.

### D (sims/bench builder)

The budget entry is under "Perf fix 1" below (final numbers).

### Studio fix 1 (fix builder)

The Studio pass found a fixture bug every Lune spec missed, because the testkit's fake instances accept
any property write. Paste as a known issue (a future framework issue: validate fake property names):

```markdown
### The Lune testkit's fake instances accept any property, settable or not (v1.8.0)

The harness's fake `Instance`s take any key: `part.Tags = {...}` or `part.ClassName = "TrussPart"`
pass every spec and sim, while the engine throws (`Tags is not a valid member of Part`; `ClassName` is
read-only) and the place never boots. Any kit's or game's world-building code can hit this. Apply
tags with `CollectionService:AddTag`, choose the class at `Instance.new`, and boot new world-building
code in Studio once. The carry kit's `FakeWorld` casts now use the engine's filter (`CanQuery`, then
`RespectCanCollide`, then collision groups), but they remain analytic boxes, not the engine's
raycaster.
```

### Perf fix 1 (carry perf fixer; numbers updated by the orchestrator at the round's end)

The KITS-ALL+carry variant still misses 1.128 ms after two optimization passes (cadence knobs, then
an allocation and stagger pass). Numbers are `tools/bench` medians of 5 runs on the round's final
head (after the unchanged-pose and cast-params fixes), with the fake world's own cost removed through
each variant's `-CTL` control. Single runs vary by about ±0.2 ms on this machine. Paste as a known
issue:

```markdown
### Carry and Movement cost more than the 20% tick budget at the default cadence (v1.8.0)

`tools/bench` (one bench tick = one second of game time, 50 players):

| Variant | Total ms/tick | Carry + Movement Luau (variant minus its control) | Engine calls per tick | Engine cost at Studio prices |
|---|---:|---:|---|---:|
| KITS-ALL+carry (12 objects × 4 carriers, 50 players sampled) | 6.44 | 3.33 | 226 Raycast, 70 Blockcast, 360 CFrame writes | ≈ 0.91 |
| MOVEMENT-50 (50 players at 10 Hz, Carry idle) | 4.93 | 2.11 | 226 Raycast, 93 Blockcast | ≈ 0.33 |
| CARRY-20x4 (20 objects × 4 carriers, Movement off) | 4.54 | 1.20 | 600 CFrame writes | ≈ 1.02 |
| KITS-ALL+carry-FLOOR (both booted, nobody playing) | 0.83–1.02 (noisy) | 0.1–0.3 over KITS-ALL-STEP | none | 0 |

The budget leaves 0.19 ms (1.128 ms, 20% over the v1.7.0 KITS-ALL reference of 0.94 ms). KITS-ALL
without the kit is unchanged (0.90 ms). Studio prices, measured on the Studio server VM (median of
5 × 1000): Raycast 0.89 µs, Blockcast 1.39 µs, anchored CFrame write 1.70 µs.

The bench stubs its casts and its carriers always walk, so it can't show the two live-only savings
below; its totals are unchanged by them within noise.

Where it goes: Movement's checks (about 3 µs per player sample, 500 samples per second at
`sampleHz = 10`) and Carry's logic step (about 12 µs per carried object at 10 Hz). The cost scales
with these knobs, largest effect first: `sampleHz` (linear in samples), `wallSweep.everySamples`,
`groundCast.skipStuds`, `motionHz`. `staggerBuckets` only spreads the samples across frames; it
doesn't change the total.

Two live-only costs are already avoided:
- A carried object held still is no longer rewritten: Carry refreshes `prev`/`target`/`tickAt` and marks the
  object dirty only when the clamped pose moves more than 0.002 studs or 1e-4 on a rotation element, so an idle
  holder costs 0 CFrame writes and 0 replication (was 30 writes per second per object).
- Movement's live casts reuse one `RaycastParams` per option set (`respectCanCollide`, `collisionGroup`,
  `ignoreCharacters`), and the character exclude list follows PlayerAdded / PlayerRemoving and each player's
  CharacterAdded / CharacterRemoving, so a cast no longer allocates params or loops `GetPlayers()` (about 300
  casts per second at 50 players). A cast with its own non-empty `exclude` list gets uncached params; nothing in
  the kit passes one.

Follow-ups, roughly 0.2–0.4 ms each: cache `humanoidFacts` per carrier per logic tick; a batch
`lastValid` for Carry. The shared ticker also creates a coroutine
for every `onTick` call (about 0.4 µs and 1.2 KB each, about 0.05 ms per second at the kit's 100
calls per second); a non-yielding fast path or a fixed-timestep lifecycle primitive would remove that,
but it is a small part of the total.
```

### Final review (orchestrator; open Medium and Low findings, not fixed this round)

The final review's three Highs were fixed (`Movement.active` fallback, the hard-landing fall floor,
the casts' collision filter). These Medium and Low findings stay open; paste as known issues:

```markdown
### Carry: open edges (v1.8.0)

- **WalkSpeed restore:** releasing an object divides the current `WalkSpeed` by the carry factor. If
  game code wrote `WalkSpeed` during the carry (a sprint, a pad, a status effect), the player keeps a
  higher speed than intended (16 written mid-carry becomes 18.8), and Movement's cap follows it.
  Avoid writing `WalkSpeed` while a player carries, or re-set it on `Dropped`/`Delivered`.
- **Model pivots:** a Model's pose is read from `GetBoundingBox()` (the box centre) but written with
  `PivotTo` (the pivot), so a Model whose pivot isn't at its box centre jumps by the offset on
  pick-up, reset and delivery. Put carriable Models' pivots at the box centre. Parts are unaffected.
- **Collision groups:** Carry's live adapter moves character parts still in `"Default"` into
  `"CarryCharacters"`, so collision rules written against `"Default"` stop applying to players. For
  about the first second after a spawn (before that move is seen), Movement's casts may still use
  `"Default"`.
- **Model parts:** `setCollide`/`setCollisionGroup` act on every part of a Model, so decorative
  non-colliding parts become solid after the first drop, and a settle restores `"Default"` on every
  part rather than each part's own group.
- **`carrierDied = false`** is effectively ignored with Movement on: the dead carrier is released on
  the next tick as `Dropped("teleport")`. Without Movement the body keeps its slot until
  `CharacterRemoving`.
- **Untagging mid-carry:** removing the tag (or the instance) while an object is carried or thrown
  leaves an instance that still exists anchored with `CanCollide` off.
- **A throw that settles inside the catch window** becomes `idle` without `Dropped("missedThrow")`
  (unlikely: settling takes at least 1 s against a 1.2 s window).
- **Re-registering** a carriable tag already watched duplicates its tag-added/removed connections.
  Movement's `startRun`/`exempt`/`setSpeedCap` for a player who already left create a state that is
  never removed.
- **Wobble** offsets Parts only; a Model gets `onWobble` events but no visual offset.
- **Hard landing is opt-in (off by default), and a game that turns it on accepts these limits.**
  - **False drop:** a jump across a ditch that lands at, or just before, a delivery zone or a hand-off can
    count as a hard landing (1–3 in 10 in the kit's sims): a fall still in the air when the delivery or
    hand-off resolves is projected straight down.
  - **Missed falls:** stepped cliffs (risers under the minimum fall, 1–2-stud treads: 24–40-stud falls drop
    0–1 in 10) and a jump off the crest of a 55–60° hillside (0 in 10; 62°: 0–6 in 10) can go uncounted.
  - A walk up a ramp or stairs, and the pick-up itself, reset where a fall is measured from, so a jump at a
    hill's crest, at the far edge of a footbridge, or as the first move after a pick-up doesn't drop (0 in 10).
- **Hard landing (when on): what it can't see.** Each fall is decided at its touchdown on its height, so the landing's
  phase inside the tick and lag don't change it (15–40-stud falls drop 10 in 10 at every phase, under 300 ms
  jitter with a server hitch at the landing, and with a 1.3–2.9 s connection freeze at mid-height; a fall next
  to or into a delivery zone, or a manual drop up to 0.4 s after the landing, is a hard landing 10 in 10).
  Jumps on flat ground, a 1-stud jump down, one jump on 34° or 45° stairs or on a ramp, walking down stairs,
  ramps and terraces of 3- or 5-stud ledges, and lifts at 12–20 studs/s never drop. Left over:
  - **Stepped terrain is judged by its single ledges.** A fall counts at most the carriers' rise plus the
    highest single ledge under the first carrier's path (a run of drops steeper than 63°). So a run across
    terraces of short ledges that never touches down between them (a 20-stud free fall over 5-stud ledges
    2 studs apart), or a slide down a slope gentler than 63°, doesn't count; a cliff, a hole or a steep
    hillside does. Only the first carrier's path is profiled, and across a freeze the path in between is
    taken as a straight line.
  - **A freeze or hover in mid-air longer than 3 s** splits a fall: a 20-stud fall frozen 3.5 s at
    mid-height drops 6 in 10 as `hardLanding`; the other 4 are released as `teleport` at the catch-up
    (Movement's teleport check, or Carry's own with Movement off).
  - **A manual drop, hand-off or throw while the carriers are still in the air** over ground at least the
    minimum fall below them is a hard landing (the fall is about to land there).
  - A fall onto a lift that is itself moving down doesn't count (the ground under the carrier moved down).
  - A lift descending much faster than 20 studs/s can read as a fall on a laggy connection, if a freeze hides
    the whole ride and the lift has stopped by the decision (40 studs/s at 300 ms: 0 in 20 with Movement
    off, 1 in 20 with it on).
  - The air test is a single ray down from the root: a carrier hanging over a ledge edge with only its
    feet's edge on it reads as in the air (harmless unless the fall is also a fast, minimum-fall drop).
  - Live-only: the rays' exclude list and collision group are checked by the Lune fake, not in Studio yet
    (Studio hand check: walk a crate off a 15-stud ledge, down a staircase with a jump, and onto a lift).
- **Held-still objects are written only on change:** while the clamped pose moves less than 0.002 studs
  (and 1e-4 per rotation element), Carry doesn't write the object, so game code that moves a held
  object while its carriers stand still isn't overwritten until they move.

### Movement: ping under Studio's network simulator (v1.8.0)

With Studio's network simulator at 300 ms, `Player:GetNetworkPing()` on the server read about 0.2 ms
while the client showed about 650 ms (client and server share one process). Movement's lag allowance
then falls back to its 0.25 s floor (0.6 s for the window and teleport cap), and a normal run still
drew no strike in the sims and in Studio. Confirm the ping-aware allowance on a deployed server with
real latency.

### The carry kit's FakeWorld can't model a server move before the client's first packet (v1.8.0)

In `FakeWorld`, a server `PivotTo` issued less than one round trip after `CharacterAdded` can read
back a stale pre-move sample. Specs keep such moves at least 2 × the base latency after spawn. A
test-world limitation, not a Movement bug.
```

**For the merge session (not known-issues text):**
- **Squash-merge `feature/v1.8-carry`, or reword commit `5c9dc83` before any push.** That first
  design-draft commit quotes a private concept name and refers to a private game; later commits
  removed both from the tree, and the privacy check passes on the tree and on `git log -p`, but a
  history-keeping merge publishes the old text.
- Round-process wording ("this round", "the prompt says", "builder C", "the orchestrator asks") is
  in `carry.md` and some test headers. Nothing private; reword to neutral text when integrating.
- `tools/doctor` in a game built from this branch prints "StudWork 1.7.1": no version bump in this
  parallel round. The modules declare `framework = "^1.7.0"`.

---

## `docs/manual-qa.md`

### A (foundation)

```markdown
## Carry kit (v1.8.0)

- [ ] Two real players on a Local Server pick up a 2-carrier object together and walk it into a
      delivery zone. `Delivered` fires once, listing both carriers. Picking it up again is refused
      until `Carry.reset`.
- [ ] A throw between two real players, caught, and then a missed catch. A missed throw becomes a
      plain drop that anyone can pick up, and it settles and re-anchors.
- [ ] Touch controls on a phone or the Device Emulator at 667x375 and 926x428: the interact button
      ("Pick up" / "Help carry" / "Drop"), the pass button and its target highlight, and the bottom
      status chip.
- [ ] A real player on Studio's network simulator at 300 ms with jitter completes a normal run (walk,
      jump, fall off a ledge, ride a tagged moving platform, sit in a seat, respawn) with zero Movement
      strikes.
- [ ] A carried object looks smooth (no 10 Hz stepping) to a second client at 300 ms. A dropped
      object pushed off the map comes back to its spawn.
```

### B / C / D (and the Studio block)

```markdown
- [ ] A carriable **Model** (with a `PrimaryPart` at one end) does not jump on pick-up, reset or
      delivery once its pivot is at its box centre; note the jump if it isn't (known issue).
- [ ] With `wallSweep = "strike"`, carrying an object past walls, through a checkpoint and past a
      just-dropped object gives zero strikes; a client-side teleport still strikes.
- [ ] On a deployed (not Studio) server with real latency, `Player:GetNetworkPing()` is non-zero
      and a normal run at about 300 ms draws no strike.
- [ ] After a cold server start, a dropped object doesn't collide with players
      (`CarryDropped` × `CarryCharacters`) but does collide with the floor.
- [ ] A crate held still for 10 s: its server CFrame changes 0 times (the idle-write skip holds against
      a live character's replicated wobble).
- [ ] Changing a character root's `CollisionGroup` in the client's command bar doesn't change what
      the server reads.
- [ ] A respawned player's new body is never hit by another player's wall sweep (no `wallSweep`
      strikes when walking through a just-respawned player).
```

---

## `tools/new-project` / `tools/new-game` (`--modules` lists)

### A (foundation)

Both tools validate `--modules` against the `KitModules` manifest, which auto-discovers every
kit module, and `"Carry"`/`"Movement"` are accepted as soon as their folders exist. **Dogfood
iteration 2 found this is a real, reproducible bug, not just an untested path:** passing
`--modules ...,Carry,Movement` to `tools/new-project` generates a `GameConfig.modules` list that
correctly includes both names, but generates the boot spec's `EXPECTED` list WITHOUT them. The
project's first commit then fails its own pre-commit hook
(`expected {..., Carry, Movement, ...} to equal {..., ...}`) and `new-project` deletes the
half-made project — a silent, total failure from the user's point of view (no project is left to
fix). **Fix for whoever adds `--modules` support for this kit:** find wherever the boot-spec
`EXPECTED` list is generated (likely from a narrower/stale list than `KitModules`'s own
discovery) and make it track the same manifest `tools/new-project` itself already uses to accept
the flag, or generate `EXPECTED` from the same `--modules` argument list directly. Add a
regression test: `tools/new-project <tmp> --modules Economy,Carry,Movement` must succeed and
produce a boot spec listing all three.

The template's default module list (with no `--modules`) is every module of the manifest's
`ORDER`, so new games and `test-adopt` boot Carry and Movement at their defaults:
- Carry has no carriables, so it does nothing.
- Movement uses `response = "log"`, and with no World under the harness it idles.

**For the integration session:** the dogfood runs added the modules to a game by hand (per the
bug above, `--modules` can't be used for Carry/Movement yet even after this kit is registered in
the template). That is a recorded stuck point, removed once the `EXPECTED`-generation bug above
is fixed and the quickstart's warning against using `--modules` for these two names is removed.

### B / C / D

None: the kit has two module folders, so `NewGame.spec.luau`'s count is 17 on this branch (15 + 2).
With the `quests` kit merged too, it is 15 plus every new kit module.

---

## `templates/` and `examples/sandbox/` (project wiring)

### A (foundation)

The project JSON is generated by `tools/sync-projects` on the branch. That is tool output only, not
a hand edit; see "Edits made on the branch" above. No sandbox **content** changes: the kit's visible
demo is the kit-owned fixture `examples/carry/`, because `examples/sandbox` is off-limits. Its
`servePort` is 34910, inside this round's 34900–34949.

To show the kit in the sandbox later (optional, for the integration session), add to the sandbox's
`GameConfig.modules`:

```lua
-- examples/sandbox/src/shared/Config/init.luau: the `modules` list, after the Leaderboards line
require(Modules:WaitForChild("Carry"):WaitForChild("module")),
require(Modules:WaitForChild("Movement"):WaitForChild("module")),
```

### B / C / D

`examples/carry/default.project.json` is kit-owned. Beyond the `sync-projects` module mapping it holds
the fixture's own hand-written `src/` mapping (server, client, shared), like every other example.

---

## Bench variants (`tools/lune/bench/replication.luau`)

### A (foundation)

The file isn't off-limits, but both rounds may add variants to it.
- **The variants:** D adds the kit-owned `tools/lune/bench/CarryVariant.luau` (the KITS-ALL+carry,
  CARRY-20x4 and MOVEMENT-50 variants; carry.md "Budget").
- **The edit:** D adds an additive registration in `replication.luau`'s `variants`, `tickFns` and
  `ORDER`, **directly on its branch**, and reports the exact lines, so the orchestrator can merge
  around the `quests` round's own variant lines.
- **The target:** KITS-ALL+carry ≤ **1.128 ms/tick** (Luau plus priced engine calls).

### B / C / D

D's edit to `tools/lune/bench/replication.luau` (+25/-2, additive; the quests round may add its own
variant lines next to these, keep both):
- a `require("./CarryVariant")` after the `SectionCache` require;
- `bootKits(players, all)` becomes `bootKits(players, all, carryPlan: any?)`, which calls
  `carryPlan.extend(modules, config)` before the harness boots and `carryPlan.start(h, list)` after
  the players join;
- `CarryVariant.register({ variants, tickFns, order = ORDER, bootKits, apis, runtimes, diff })` right
  after `ORDER` is defined;
- `CarryVariant.report()` at the end (the engine-call table).

The variants (`KITS-ALL+carry-FLOOR`, `-CTL`, `KITS-ALL+carry`, `MOVEMENT-50(-CTL)`,
`CARRY-80-CTL`, `CARRY-20x4`, plus `KITS-ALL-STEP`) step 30 × 1/30 s per bench tick so every handler
runs at its real cadence, and each has a control that boots the same fake world without the modules.
First floor-only measurement: `KITS-ALL+carry-FLOOR` 0.96 ms (D), 0.83 ms on the final head. Final
numbers: see the known-issues entry under "Perf fix 1".
