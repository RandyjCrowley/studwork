# Known issues

Open problems in StudWork that are known, understood and not yet fixed. Each entry says where the
problem is, what fails, and what to do until it is fixed. Fixed issues are listed only by id
at the end ("Fixed ids"); `CHANGELOG.md` has the details.

**Ids.** `R<n>` ids come from the framework's code reviews and keep their original numbers, so gaps
in the sequence are issues that have since been fixed. `V<n>` ids are issues that only show up when
StudWork is used from a games repo (as a submodule). `S<n>` ids only show up in a single-game project (v1.5.0). `O<n>` ids are smaller limits that were noted
without a review id.

**Severity.**
- **High:** can lose or duplicate player data or purchases in realistic use.
- **Medium:** wrong behaviour or a guardrail gap that needs care from game code or reviewers.
- **Low:** an edge case, a cosmetic problem, or a limit that is unlikely to matter in practice.

There are no open Critical or High issues.

## Medium

### R3. An unsent gift waits for its sender
- **Where:** `packages/kits/social/Mail/server/Outbox.luau`.
- **What fails:** a gift is written to the sender's outbox and saved before it is sent. If the server
  shuts down or the sender leaves before the send succeeds, the outbox is retried once more on leave
  and again at the sender's next login, but not from any other server (that would need the sender's
  save session). A sender who never returns leaves the gift undelivered. The item is never lost or
  duplicated, only delayed.
- **Workaround:** none needed for correctness; tell players that gifts can take until the sender's
  next visit if a server closes mid-send.

### R9. The "games don't edit the framework" guardrail is a convention in the framework repo
- **Where:** `tools/lune/guardrails.luau` (`packages` check).
- **What fails:** inside this repo the check works on branch names (`game/*` branches may not change
  `packages/`) and on staged changes that mix `packages/` with game files. A `packages/` change
  committed on its own on a branch with another name, or anything already merged, is not caught. (In
  a games repo the check is strict: the framework submodule must sit exactly on a release tag.)
- **Workaround:** review merges of game branches.

### R25. The framework still carries v1.2-shaped kit data
- **Where:** `packages/framework/shared/Types.luau` (`BalanceConfig` sections such as `income`,
  `inventory`, `rarityTables`, `upgrades`, `rebirth`, `offline`, `streak`, `friends`, `plot`, and
  `PlayerData.mail`), the flat `ReplicatedState` fields (`ratePerSec`, `multiplier`, `plotName`,
  `odds`, `mailbox`) filled by `Replication/Snapshot.build` and the client `State`,
  `FrameworkSection.V12_MAP`, and the default theme's `rebirth`/`streak` sounds.
- **What fails:** nothing at runtime, and no kit gets a capability a third-party module lacks (module
  state lives under `state.modules.<Name>`, config under `config.<Name>`). But the framework still
  knows these lower-case kit shapes, which the `special` guardrail does not flag. Removing them would
  break the v1.2-compatible client surface and saves made before v1.3.
- **Workaround:** new modules should use their own section, config and `state.modules.<Name>`, never
  the flat fields. Planned fix for a major version: move the kit types into each kit's
  `module.luau`, drop the flat view, and let the scan derive each kit's `data.key`.

### O28. Movement content rules: server-side doors, tagged platforms, gravity

- **Doors:** a door opened only on the client is still solid on the server, so walking through it is
  a `wallSweep` strike. Open doors on the server, or make them non-colliding there.
- **Platforms and conveyors:** a moving platform or conveyor must carry a `platform` volume tag to be
  measured relatively. A client-simulated platform also needs `Movement.registerPlatformSource`.
- **Gravity and forces:** low-gravity zones and custom forces (jump pads, knockback) must call
  `Movement.exempt` or raise `arc.gravitySlack`.

### O29. The Lune testkit's fake instances accept any property, settable or not

The harness's fake `Instance`s take any key: `part.Tags = {...}` or `part.ClassName = "TrussPart"`
pass every spec and sim, while the engine throws (`Tags is not a valid member of Part`; `ClassName` is
read-only) and the place never boots. Any kit's or game's world-building code can hit this. Apply
tags with `CollectionService:AddTag`, choose the class at `Instance.new`, and boot new world-building
code in Studio once. The carry kit's `FakeWorld` casts now use the engine's filter (`CanQuery`, then
`RespectCanCollide`, then collision groups), but they remain analytic boxes, not the engine's
raycaster.

### O30. Carry and Movement cost more than the 20% tick budget at the default cadence

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

### O31. Carry: open edges, and the limits of opt-in hard landing

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

### O35. Promotion code retirement is permanent
- **Where:** Codes (`packages/kits/player/Codes/`).
- **What fails:** settled removed-code history is pruned to bound player saves, so a retired code id
  that comes back (including through a config rollback) has lost its once-only history and becomes
  redeemable again. Pending receipts and their markers are never pruned. An explicit
  `oncePerPlayer = false` is refused in this version.
- **Workaround:** never reintroduce a retired id; give a new promotion a new id.

### O37. Framework console commands ignore Admin roles
- **Where:** the framework console (`economy grant`, `data dump` and the other framework commands).
- **What fails:** these commands keep the framework's admin rule (`ServerConfig.admins`); no hook lets
  a module govern them, so the moderation kit's roles and limits don't apply to them. Every kit
  console command also runs as `by = "console"`, so the audit can't tell who typed it.
- **Workaround:** keep `ServerConfig.admins` to people trusted with every command. Proposed for a
  later release: a console permission hook and `ctx.framework.isAdmin(player)` (module-api §24.2).

## Low

### R11. Purchase effects are dropped if the final save fails after the buyer leaves
- **Where:** `packages/framework/server/Shop/` (see its README).
- **What fails:** if the buyer leaves while a grant's save is unconfirmed, the framework makes one
  more confirmed save and then runs the `tx.after` effects. If that save also fails, the effects are
  dropped with a warning. The grant itself is safe: it is in the save, or the receipt is retried.
- **Workaround:** never put grant logic in `tx.after`; it is for effects (toasts, sounds,
  analytics), and must not assume the buyer is still in the server.

### R12. `tools/publish` trusts `deploy.json`
- **Where:** `tools/lune/PublishGate.luau`.
- **What fails:** the "tested before live" gate reads `test.published.commit` from `deploy.json`;
  hand-editing it unlocks `--live` without a test publish.
- **Workaround:** don't edit the publish stamps by hand; review `deploy.json` changes.

### R17. Mail handlers before a `false` run again on claim
- **Where:** `packages/kits/social/Mail/server/Delivery.luau`.
- **What fails:** when one handler of a mail kind returns `false` ("can't accept now"), the handlers
  before it have already run, and they run again when the message is claimed from the mailbox.
- **Workaround:** documented contract: mail handlers must be safe to run twice.

### R18. ProcessReceipt replacement can't be detected on live servers
- **Where:** `packages/framework/server/Shop/`, `packages/framework/server/Platform.luau`.
- **What fails:** `MarketplaceService.ProcessReceipt` is write-only in the engine, so the framework's
  runtime check (warn, analytics event, reclaim) only works with the test platform. Live,
  `receiptCheck().status` reports the check as unavailable.
- **Workaround:** enforcement is the `purchases` lint guardrail plus Shop claiming the callback as
  the very last boot step. Never assign ProcessReceipt yourself; patch vendored packages that do.

### R21. Only the last 200 receipts are remembered
- **Where:** `_framework.purchases` (`packages/framework/server/Data.luau`, `PURCHASES_CAP`).
- **What fails:** a receipt that Roblox re-delivers after more than 200 newer purchases by the same
  player could be granted twice.
- **Workaround:** none needed in practice. The fix (receipts in their own section) is a data-contract
  change, left for a later version.

### R23. Writing `_framework` every tick is slow
- **Where:** framework data commits.
- **What fails:** a module that writes into `_framework` every tick costs about 1.6–1.9 ms per tick
  at 50 players, because each commit re-walks the stored receipts. The shipped kits don't do this
  (0.60–0.65 ms per tick).
- **Workaround:** keep per-tick stats in your module's own data section.

### R24. Wide display fonts can crowd the HUD
- **Where:** framework HUD (action bar).
- **What fails:** with a wider theme display font, auto-widened action-bar buttons can touch the
  top-centre HUD in a small viewport. Cosmetic.
- **Workaround:** pick a narrower display font or shorter action labels.

### R26. Runtime-built names evade the framework scan
- **Where:** `tools/lune/guardrails.luau` (`special` check).
- **What fails:** names built at runtime (`string.char`, `string.format`, `string.reverse`,
  `table.concat`, `gsub`) are not seen. Lint guards against mistakes, not deliberate obfuscation.
- **Workaround:** review framework merges.

### R27. One sim spec doesn't guard the save-version bump
- **Where:** `packages/framework/test/sim/` (the stolen-save / `saveNow` version case).
- **What fails:** the sim spec passes even without the `_framework` version bump on `saveNow`,
  because ProfileStore's own `beforeSave` bumps it during the save.
- **Workaround:** the unit spec `packages/framework/test/SaveNowVersion.spec.luau` is the regression
  guard; keep it.

### O1. A long DataStore outage at join leaves the player waiting
- **Where:** `packages/framework/server/Store.luau` (`StartSessionAsync` with `Cancel`).
- **What fails:** the load cancels only when the player leaves, so ProfileStore's own load timeout is
  off and a player waits unloaded, without a kick, until the outage ends. Defaults are never written
  over an existing save (tested).
- **Workaround:** none; the loading screen stays up.

### O2. Net's pre-start queue is shared
- **Where:** `packages/framework/server/Net/init.luau` (`PENDING_CAP = 256`).
- **What fails:** requests that arrive before boot finishes are queued in one buffer for all players
  and events; past 256 they are dropped.
- **Workaround:** none needed; boot is short.

### O3. Odds don't show a pity-adjusted long-run rate
- **Where:** `OddsDetail` (Rarity kit).
- **What fails:** disclosed odds are per roll; the effective rate including pity is not computed.
- **Workaround:** describe pity in the game's own UI text if you use it.

### O4. ProfileStore always writes once when a session ends
- **Where:** framework Data/Store.
- **What fails:** on a migration failure the player is kicked and the session ends with one save of
  the untouched loaded data (never defaults). Harmless, but it is a write.
- **Workaround:** none needed.

### O5. A failed `capBonus` counts as no bonus
- **Where:** `packages/kits/collection/Inventory/server/init.luau` (`capOf`),
  `packages/kits/economy/Economy/server/init.luau` (`recompute`, `rateFactor`).
- **What fails:** both kits pcall a bonus function and treat an error as 0. A bonus that asks
  `ctx.shop.ownsPass` for a pass whose lookup hasn't answered yet (v1.6.1: an error inside a
  transaction) then counts as no bonus until it answers: a lower cap or rate, never a higher one.
  Purchases are not affected (the retry survives the pcall).
- **Workaround:** none needed for correctness; read pass perks after the player loaded, or track
  them with `ctx.shop.onPassOwned`.

### O6. Undeclared legacy writes are only caught in tests and Studio, and not every kind
- **Where:** `packages/framework/server/Shop/` (`onLegacyProduct`, v1.6.1).
- **What fails:** a write deferred past the old handler's return (`task.defer`, `task.delay`, a
  later event) isn't caught. In Studio only the keys the registered `importLegacy` sources read are
  compared (no import, no comparison), and nothing is compared with API access off. Live servers
  only get the boot warning.
- **Workaround:** the bridge is for test places only, and `tools/adopt --verify` refuses it before
  a live publish.

### O7. The legacy anchor and the adopted marker live in git history
- **Where:** `tools/lune/guardrails.luau`, `tools/lune/AdoptedMarker.luau`.
- **What fails:** a history rewrite resets both. In a project with no remote (or never pushed) that
  can't be detected; `tools/lint --anchor-remote` needs a remote default branch and full history.
  If the adopted flag is absent and history is shallow or unavailable, lint requires `--verify`
  to pass; `tools/publish --live` refuses there.
- **Workaround:** push the adoption commit and run `tools/lint --anchor-remote` in CI (the
  single-game CI template does).

### O8. Notifications and badges send nothing real until you replace the placeholders
- **Where:** `config.Notifications.templates.*.messageId`, `config.Badges.badges.*.id`.
- **What fails:** a template with an empty `messageId` and a badge with `id = 0` are placeholders:
  the framework records, logs once per server and never calls Roblox. A game that forgets to
  replace them ships with silent no-ops.
- **Workaround:** the first send or award logs a warning naming the key; check the Output on a
  test place.

### O9. Scheduled notifications need a running server, and an empty server sends very few
- **Where:** `packages/kits/engagement/Notifications/`, `docs/framework/kits/notifications.md`.
- **What fails:** a future send ("your egg is ready") is sent by whichever server polls the due
  list; with none running at the due time it waits for the next server and is dropped once older
  than `schedule.staleAfterHours`. Every store call also counts against the server's MemoryStore
  request cap (`storeBudgets.memoryUnits`, module-api §23.5): a server with 0 players has 20
  units a minute, and a send costs about 6 units and a due entry about 9, so it sends about 3
  notifications a minute (each player adds 20 units). Over the cap a send answers `store_busy`.
- **Workaround:** raise `storeBudgets.memoryUnits.base` if reserved or empty servers must send
  many; keep the stale window longer than the longest expected gap between servers.

### O10. A notification rescheduled during its own send can be lost
- **Where:** Notifications due list, `Sender`/`Engine`.
- **What fails:** if the same user and key is rescheduled while that key's send is in flight, the
  removal after the 2xx deletes the new entry (the ledger still lists the key until it goes
  stale).
- **Workaround:** use a different `key` for a reschedule made at the moment of sending.

### O11. The `textfilter` and `strings` lint checks are heuristics
- **Where:** `tools/lune/GuardTextFilter.luau`, `tools/lune/GuardStrings.luau`.
- **What fails:** `textfilter` follows a string through one function only (an inline handler or a
  function defined in the same file); it misses text that crosses functions, files or tables. `strings` reads one line at a time, so a
  text prop whose value continues on the next line is not followed.
- **Workaround:** review player-text paths by hand; the TextFilter page lists the safe pattern.

### O12. Store limits are only partly enforced from one server
- **Where:** `ctx.data.ordered`, `ctx.data.sortedMap`, `GameConfig.storeBudgets`.
- **What fails:** the experience-wide ordered-store throttle is recognised by its error text
  (`HTTP 429` / `Too Many Requests`), which is assumed, not observed; a memory total lags by up to
  `censusSeconds`; the census's own items are not charged to any module share; an ordered
  `increment` is never retried and may or may not have applied after a failure.
- **Workaround:** keep `orderedReserve` and the memory `reserve` at their defaults or higher; write
  absolute values with `set`/`update`.

### O13. A server crash can lose up to 30 s of Leaderboards `max`/`sum` submits
- **Where:** Leaderboards pending submits (`packages/kits/engagement/Leaderboards/server/init.luau`).
- **What fails:** a `submit` on a `max` or `sum` board is combined in memory and joins the player's
  save within 30 s (and before each store write, on leave and on shutdown). A server that crashes
  inside that window loses those submits, on top of the usual autosave window; a clean shutdown or
  leave loses nothing. `set` boards and `txApi.submit` write the save straight away.
- **Workaround:** for a value that must survive a crash (a paid or rare result), submit it with
  `txApi.submit` inside the transaction that grants it.

### O14. A server crash can lose up to 30 s of partial quest progress

Quests folds non-completing progress into the save every `foldSeconds` (default 30). A crash in
between loses that partial progress (never a completion or a claim). Lower `foldSeconds` to shrink
the window at some tick cost.

### O15. Goals can't check Quests' funnel steps

`ctx.analytics.funnel` drops a step that isn't in `GameConfig.analytics.funnel`. Goals logs a boot
warning per goal whose `funnel` step isn't listed; Quests' per-quest `funnel` is not checked. The kit
page says to list every step.

### O16. One reset time for every player

Daily and weekly quests reset at one moment per game (`utcOffsetHours`), not at each player's local
midnight: the client's clock can't be trusted. Pick the offset for your main audience. The offset is
fixed, so where that audience observes daylight saving time the local reset hour moves by one twice
a year.

### O17. The goal pointer can't see a target that never streamed in

With `StreamingEnabled`, a tag or path target that was never streamed in to this client has no
position; the pointer uses the goal's `fallback` if set, otherwise it shows the pill only.

### O18. `currencyEarned` counts every positive balance change except quest rewards

The built-in `currencyEarned` source adds every `CurrencyChanged` with `delta > 0` whose reason
doesn't start with `"Quests:"`. A game where currency can be moved back and forth (sell and buy back,
trades, gifts) lets a player farm it. For such objectives use a counter (`Quests.progress`) from the
code paths that should count.

### O19. A completion can be about a second behind

`Quests.progress` and `Goals.complete` never open a transaction (so they are safe inside a game's
own), so a completing increment is written on the next 1-second tick. `Completed`, auto-claims and
goal funnel steps follow then, and a crash in that second loses the completion (it can be redone).

### O20. The next-goal provider re-runs only on a relevant signal

Past the chain, `Goals.setNext`'s provider runs on load, at the hand-over and when one of the
signals Goals listens to fires (Quests, Economy, Inventory, Rebirth, Streak, registered sources),
at most once per `nextSeconds`. An answer that depends on something else (time of day, a game
value with no signal) updates on the next such signal. Register a source with a `changed` signal
for it, or call `Goals.setNext` again to refresh everyone.

### O21. Quests tick cost in the worst-case bench is over the v1.7.0 budget (accepted for v1.8.0)

**Accepted for v1.8.0.** `tools/bench` variant `KITS-QUESTS` is a stress case: KITS-ALL plus Quests and
Goals, 50 players each progressing all 10 active quests every bench tick (one `progress` call per
player per tick on a key shared by all 10 quests: 500 quest updates per tick), `replicateSeconds = 1`. It measures ~1.34 ms per tick against KITS-ALL's ~0.85
(budget 1.128).
The bench without the kit (KITS-ALL) is unaffected and stays within its budget. A real game rarely moves
every quest of every player every tick. About 0.24 ms is the floor of having the modules loaded: the
framework re-snapshots every module's replicated state each tick (~0.10), folds (~0.09) and `progress`
(~0.05); the rest is the live-progress sends at a 1 s cadence. The default stays `replicateSeconds = 1`
so progress feels live; busy games can raise it to 3 (~1.23 ms) or 5 (~1.14 ms, with
`foldSeconds = 120`).

**Follow-up for v1.8.1 (framework):** the replication step clones each player's wrapper tables every tick
(`packages/framework/server/Replication/init.luau`, around line 139: the merged `extra` table in
`moduleState`, and line 160: the framework table in `build`) and re-copies any module whose data
changed. Reusing unchanged wrappers and copying only what changed makes every module cheaper, not
only Quests.

### O22. Unsaved quest progress is dropped when the Quests flag goes off and the player leaves

While `Quests.flag` is off nothing is evaluated or folded, and the leave and shutdown folds also
return early. Progress counted in memory since the last fold (up to `foldSeconds`, 30 by default) is
lost for a player who leaves while the switch is off. Completions and claims already written are
kept. Turn the flag off only when losing that window is acceptable.

### O23. Quests rebuilds its requirement index on every item added when a quest uses `requires.items`

When any quest has `requires.items` or `requires.rebirths`, each `ItemAdded` and `Rebirthed` marks the
player's index stale and the next `progress` or tick rebuilds the whole index. That is cheap at normal
item rates; a game that adds items to a player every tick pays one rebuild per player per tick (the
bench doesn't cover it). Batch item grants, or keep the `requires` lists short.

### O24. Studio shows warnings that are expected in an unpublished place

In a place that isn't published (or has no Studio API access) the Output shows, none of it from the
quests kit: `[StudWork.Data] DataStore API unavailable in Studio (NoAccess); using
ProfileStore.Mock - data will not persist.`; `[StudWork] Studio has no API access: ctx.data.sortedMap
maps and the census use in-memory stores for this session (nothing is kept)`; `[profilestore]: Roblox
API services unavailable - data will not be saved`; `[StudWork] no translator for a player after 4
attempts; using English` (the translator isn't reachable, text falls back to English); and the
engine's `ContentId: rbxassetid://203785492 failed due to: Asset type does not match requested type`
at join (a Roblox default asset, also in an empty place). Publish the place and enable Studio access
to API services to see the real data path; none of these is a kit bug.

### O25. The claim toast can cover the quest board's title bar

Toasts are placed by the framework HUD's toast host (top centre, 96 px down), above open screens, so a
"Reward claimed" toast briefly covers the board's title while it shows. Cosmetic; the board stays usable.

### O26. Movement can't see a teleport-and-back within one sample

Movement samples at `sampleHz` (10 Hz by default). A teleport out and back within 0.1 s leaves no
trace in the samples. Raising `sampleHz` narrows that window, at a proportional tick cost.

### O27. Short hops below Movement's teleport cap are caught only if they cross a tagged volume

The per-sample teleport cap is sized so a real player on a 300 ms connection with jitter never
strikes. That is about 14 studs per sample at the defaults (`docs/framework/kits/carry.md` "Worked
numbers"). A single shorter hop is caught only if it crosses a `hazard`, `noEntry` or `checkpoint`
volume (the path sweep is exact). Repeated hops add up in the 4 s speed window and are caught there.
Tag the volumes that matter.

The same holds for a single hop inside the respawn envelope (at most about 17 studs, once per spawn),
and for a drop shorter than the descent bound (about 56 studs per sample from standing, more across a
server hitch or while already falling), such as a short drop through a floor: the wall sweep is
horizontal, so it doesn't see vertical noclip.

### O32. Movement: ping under Studio's network simulator

With Studio's network simulator at 300 ms, `Player:GetNetworkPing()` on the server read about 0.2 ms
while the client showed about 650 ms (client and server share one process). Movement's lag allowance
then falls back to its 0.25 s floor (0.6 s for the window and teleport cap), and a normal run still
drew no strike in the sims and in Studio. Confirm the ping-aware allowance on a deployed server with
real latency.

### O33. The carry kit's FakeWorld can't model a server move before the client's first packet

In `FakeWorld`, a server `PivotTo` issued less than one round trip after `CharacterAdded` can read
back a stale pre-move sample. Specs keep such moves at least 2 × the base latency after spawn. A
test-world limitation, not a Movement bug.

### O34. Companion rendering still needs device and streaming coverage
- **Where:** Companions client following and custom game model art.
- **What fails:** the kit bounds selected model count and update frequency. Actual mesh triangles,
  transparent shells, custom effects and Animator work remain asset-dependent. Mesh triangle counts
  in diagnostics are game estimates, with unknown meshes reported separately. Local followers can
  pass through obstacles: they intentionally do not compute navigation paths or affect gameplay
  positions.
- **Trade integration:** the current Inventory removes pending gifts from ownership but exposes no
  separate reservation registry. A custom trade module must register `canEquipWith` and refresh
  immediately when its reservations change.
- **Workaround:** measure on a low-end phone and with many players under StreamingEnabled. A real
  two-player local server remains necessary to verify each player sees the other's companions.

### O36. Abandoned promotion reservations can reduce a capped code's capacity
- **Where:** Codes, capped definitions (`ctx.data.shared`).
- **What fails:** a server that dies before a receipt is confirmed can leave a capped slot reserved.
  Reservations never expire automatically, which keeps the global cap at the cost of availability,
  so a capped code can underfill.
- **Workaround:** diagnose counts through `Codes.uses`; do not decrement completed uses or release an
  uncertain reservation.

### O38. Admin: staff roles and limits are per server and per session
- **Where:** Admin (`packages/kits/moderation/Admin/`).
- **What fails:**
  - **Per-staff limits are per server.** `actionsPerMinute` and `bansPerHour` live in one server's
    memory; a staff member who hops servers gets a fresh count. Bans are also recorded in the staff
    member's own audit index (`a/u/<staffUserId>`), so a spree shows up in one place.
  - **A role is fixed for the session.** A group demotion applies on the next join (the Admin `flag`
    is the emergency switch).
  - **Admin off: per-module admin lists and no per-staff limits.** A module can't read top-level
    `ServerConfig.admins`, so `ServerConfig.Moderation.admins` and `ServerConfig.Reports.admins` are
    separate lists, and those staff are not rate-limited by the kit (`actionsPerMinute` and
    `bansPerHour` live in Admin; Net limits cover only client requests).
  - **Studio and the rank rule.** In Studio everyone is staff, so the outranked check is skipped for a
    target whose role comes only from `studioRole`; self-action is still refused, and targets listed
    in `ServerConfig.Admin.users` are checked normally.
  - **Registered tab cells aren't filtered.** Admin sends a registered tab's string cells as given (at
    most 200 characters).
- **Workaround:** a game puts only keys, numbers or already-filtered text in registered tab cells;
  use the Admin `flag` to remove a demoted staff member's powers at once.

### O39. `ctx.data.shared` has no read
- **Where:** the moderation kit's shared keys (the audit day directory, the per-target audit index,
  `bans/p/<userId>`, `r/t/<userId>`).
- **What fails:** the kit's "reads" of shared keys are `update`s returning `old`, i.e. full writes
  that spend the per-server DataStore budget player saves also use. The kit avoids polling them
  (sorted map indexes instead), rate-limits audit reads (one per 5 s per staff, cached 30 s) and
  bounds a day read to the directory plus `audit.chunksPerRead` chunks, so older chunks of a busy day
  need more pages.
- **Workaround:** none in the kit. Proposed framework fix: `ctx.data.shared.get(key)` (module-api
  §24.3).

### O40. Moderation's sorted map index entries expire
- **Where:** the `pending` and `queue` sorted map indexes (Moderation, Reports).
- **What fails:** both use a 7-day expiry. A pending entry is renewed while it is retried; an open
  report not touched for 7 days drops out of the queue index and is closed: the next read or report
  of that target deletes or restarts its per-target key (reporter ids dropped). A key that is never
  touched again stays in the store (unlisted); likewise an audit index `a/u/<userId>` drops expired
  entries only on its next write (every read hides them). A periodic sweep of both would need a key
  listing the store doesn't offer.
- **Workaround:** work the report queue within a week.

### O41. Reports: open edges
- **Where:** Reports (`packages/kits/moderation/Reports/`).
- **What fails:**
  - **Report caps are per account.** Many alt accounts can file many reports, push single-reporter
    reports out of a full queue (`queue.maxOpen`) and fill a target's 20-note cap first. Possible
    later: weigh eviction by account age, keep one note per distinct reporter, alert on evictions.
  - **Report outcome timing.** An accepted report waits for the note filter and two store writes
    before the "thanks" toast; a capped one answers at once, so a client timing the toast can tell
    them apart. Possible later: send the toast first and run `submit` in a spawned thread.
  - **Reports about players who left can be hidden with group roles.** The viewer rule uses only
    ranks Admin knows without a lookup; with `ServerConfig.Admin.groups`, a player's rank is known
    while they are in a server and for `groupCacheSeconds` (600) after. Later, reports about them are
    hidden from staff (fail closed) until they are in a server again; `by = "server"` and the console
    still list them. Possible later: a budgeted background lookup for hidden targets on the tab.
  - **Deep Reports tab pages need paging forward.** A fetch reads at most two index pages, so a page
    far past the staff member's current walk (e.g. jumping to page 40) is empty until the pages
    before it were fetched within 30 s; `queue()` from code reads the whole index.
- **Workaround:** games whose staff work the queue later can raise `groupCacheSeconds`.

### O42. Moderation: open edges
- **Where:** Moderation (`packages/kits/moderation/Moderation/`).
- **What fails:**
  - **"sent" means queued.** A cross-server message waits for the owning server's ping (one per 6 s
    per profile) or its next autosave (minutes); a kick older than `kickMaxAgeSeconds` (600 s) on
    arrival is dropped and audited `"failed"`.
  - **Private reasons need TextFilter.** Free text, `privateReason` included, is refused without
    TextFilter, so a game without it bans with presets only.
  - **TextFilter's `maxLength` defaults to 40.** Report notes (`Reports.note.maxLength` 120) and
    announcements (`Admin.announce.maxLength` 200) longer than that are refused by TextFilter (notes
    dropped) until the game raises `config.TextFilter.maxLength`.
  - **A pending ban kept in memory only** (`Moderation.note.pendingUnsaved`, store and index both
    down) is retried by that server alone; if it shuts down before the store is back, the ban is lost
    (the audit entry remains).
  - **No numeric rate limits are documented** for `BanAsync`, `GetBanHistoryAsync` or group lookups;
    the kit backs off and budgets, but the right budget is unknown.
  - **Operational sizes stay in code:** the 200-entry sorted map page, the Reports tab's 20 rows and 3
    detail reads, 100 reporters and 20 notes per report, 50 recently-left players, Admin's
    100-row/12-column/30000-byte `Rows` limits, the sweep's `retentionDays + 7` look-back.
- **Workaround:** raise `config.TextFilter.maxLength` when the moderation kit is on. Sizes that games
  need to tune can move into config later (additive).

### O43. `tools/make-module` scaffolds `framework = "^1.3.0"`
- **Where:** `tools/make-module`, `templates/module/`.
- **What fails:** a module that uses a v1.7.0+ kit (the moderation kit needs `^1.7.0`) must raise the
  range by hand.
- **Workaround:** edit `framework` in the new `module.luau`. Proposed: scaffold
  `"^<StudWork.VERSION major.minor>.0"` of the checkout running the tool.

### O44. Generated specs are `--!nocheck` and testing.md doesn't say why
- **Where:** generated `*.spec.luau` files, `docs/framework/testing.md`.
- **What fails:** `require(script.Parent.ServerConfig)` (testing.md's own example) is "Unknown
  require" in a `--!strict` spec, since specs aren't in the sourcemap.
- **Workaround:** keep `--!nocheck` in specs (the scaffold's convention), or cast requires
  `(require :: any)(...)` in a `--!strict` one. The moderation kit page says this meanwhile.

### O45. `tools/sync-projects` keeps a deleted `client/` mapping
- **Where:** `tools/sync-projects`.
- **What fails:** after `tools/make-module` and deleting the generated `client/` folder, the module's
  client mapping stays in `default.project.json`.
- **Workaround:** remove the mapping by hand.

### U1. `UI.Modal` needs a ScreenGui with `ZIndexBehavior = Sibling`

Under `Global` (the default of `Instance.new("ScreenGui")`) the backdrop draws over the panel's
contents, so the window looks blank; only the close button shows. The Modal warns once.
Workaround: set `ZIndexBehavior = Enum.ZIndexBehavior.Sibling` on the ScreenGui (the template and
examples do).

### U2. Scaled kit text doesn't grow on large screens

Rarity badges, odds percentages and panel titles are `TextScaled` with a `UITextSizeConstraint`,
which the engine applies in real pixels after UIScale: on desktop and tablet (responsive scale
1.75) they stay at 14-24 px while fixed text grows, so they look small next to item names. Never
below `minTextSize`. Workaround: none needed for readability; a game can pass its own sizes.

### U3. A wrapped, truncated name can end without "…"

The engine sometimes ends the second line at a word break without drawing the ellipsis (seen on
desktop and tablet: "Rainbow Sword of"). The odds table shows the full name on tap.

### U4. A long odds window has two scroll areas

`OddsTable` scrolls its own list (`maxHeight`, default 320) and the Modal scrolls its content.
Workaround: pass a larger `maxHeight` when the table is the only content of a window.

### U5. React views of the v1.7.0 UI are not exercised in Lune
- **Where:** `packages/ui/Leaderboard.luau`, `packages/kits/engagement/Leaderboards/client/Views.luau`, `UI.useText`/`UI.useLocale`.
- **What fails:** Lune has no React renderer, so the components' trees, the `useText` re-render on a
  language change and the Charm selectors are checked only through their pure helpers and fake
  hooks. `tools/studio/ui-text-fit.luau` has not been run on `UI.Leaderboard` with long names.
- **Workaround:** `docs/manual-qa.md` has the Studio checks; run the text-fit audit before a launch.

### U6. A badge toast can sit under right-side HUD buttons

Seen with the Badges Studio preview toast ("... (Studio preview, not sent)"): the HUD's feedback
toasts (`packages/framework/client/Hud`, top centre, 96 px down) and a HUD button column on the right
can overlap on narrow screens. Cosmetic. Workaround: a custom HUD `layout` places the `toasts`
element it is given, or set the badge's `toast = false` and show the game's own effect from the
client `onAwarded`.

## Games-repo mode

### V2. Generated module READMEs have a wrong docs link in a games repo
- **Where:** `templates/module/README.md.tmpl` (written by `tools/make-module`).
- **What fails:** the README links `../../../../docs/framework/...`, which is right inside this repo
  but not inside a games repo (the output was kept byte-identical to v1.3.1).
- **Workaround:** fix the link by hand, or point it at the framework's docs online.

### V3. Games mode depends on Rokit's storage layout
- **Where:** `tools/_common.sh`.
- **What fails:** in a games repo the tools link Rokit's tool storage
  (`~/.rokit/tool-storage/<owner>/<repo>/<version>`) into `.cache/studwork-bin/`, because Rokit can't
  be pointed at the core's `rokit.toml`. A change to Rokit's storage layout breaks this.
- **Workaround:** if tools aren't found, check that path; the fix is in one place.

### V4. The pin guardrail runs from the pinned framework
- **Where:** the `packages` guardrail, run from the submodule.
- **What fails:** pinning a tag older than v1.4.0 disables the pin check, because older releases
  don't have it.
- **Workaround:** only move the pin forward.

Fixed in v1.4.1: **V1**, the games-repo pre-commit hook failing the pin check on every commit (git's
hook environment broke the check's `git -C` calls).

## Single-game projects

`S<n>` ids are issues that only show up in a single-game project (`tools/new-project`, v1.5.0).

### S1. `tools/new-project` leaves parent folders it created after a failure
- **Where:** `tools/new-project` (cleanup removes only the target folder).
- **What fails:** `tools/new-project deep/a/b ...` that fails (for example a missing tag) removes `b`
  but leaves `deep/a`. Nothing it didn't create is ever deleted.
- **Workaround:** remove the empty folders by hand, or create the parent folder first.

### S2. A project created inside another git repo is a silent nested repo
- **Where:** `tools/new-project`.
- **What fails:** no warning when the target is inside another repository's working tree; the outer
  repo then shows the project as untracked.
- **Workaround:** create projects outside other repos (or add them to the outer repo's ignore file).

### S3. The layout marker is matched as text
- **Where:** `tools/_common.sh` (`layout_of`) and `tools/lune/Roots.luau` (`isSingleMarker`).
- **What fails:** any `"layout": "single-game"` in `studwork.json`, even nested under another key,
  switches the project to single-game mode, and the core folder's name isn't checked against it.
- **Workaround:** keep `studwork.json` as `tools/new-project` writes it; never add the marker to a
  games repo.

### S4. The sim loads only `src/` and `modules/` of a single-game project
- **Where:** `packages/framework/test/sim/Loader.luau`.
- **What fails:** a game that maps another top-level folder in `default.project.json` gets it in the
  place, linted and type-checked, but a `Boot.spec` running in the sim doesn't see it.
- **Workaround:** keep game code under `src/` and `modules/` (the layout `tools/new-project` makes).

### S5. `tools/new-project` can only pin a release tag
- **Where:** `tools/new-project`, `docs/framework/single-game-project.md`.
- **What fails:** only `--tag vX.Y.Z` is accepted, so an unreleased kit on a branch can't be tried in
  a fresh project, and the page doesn't say so.
- **Workaround:** clone the branch locally, make a local annotated tag in that clone only, and pass
  the clone as `--url` with that `--tag` (the moderation kit page shows this). Proposed: `--ref
  <branch|sha>` for trying a branch (never for a real game; the lint keeps refusing an untagged
  `studwork/` HEAD for publishing).

### S6. `tools/new-project`'s final hint names the game
- **Where:** `tools/new-project`.
- **What fails:** it prints new-game's "Next: ... `tools/dev <name>`", but in a single-game project
  the tools take no game name (`tools/dev`).
- **Workaround:** run the tools without a game name. Proposed: a single-game hint without the name.

## Not verified live

Some behaviour needs a person in Studio: Local Server with one and two clients, Device Emulator
presets, listening to the sounds, and the real DataStore on a published test place.
`docs/manual-qa.md` has the checklist; the automated cover is in `packages/framework/test/sim/`.

The v1.7.0 modules have never run against the real services: the checks for Open Cloud notification
delivery and response shapes, `AwardBadgeAsync`, real `FilterStringAsync` output by audience,
OrderedDataStore and MemoryStore throttling and billing, ConfigService propagation, translators and
`LocalizationTable`s, and two-server behaviour (the leaderboard reader lease, the notification claim
race) are listed in `docs/manual-qa.md` under "New in v1.7.0", and each kit page names what it
assumes under "Not verifiable offline".

The v1.8.0 kits have not run against live services either. Not checked yet: the quests kit's
board, pointer and reset time on devices and under StreamingEnabled; Carry with real players and
latency (Movement's ping-aware allowance needs a deployed server, O32); companion rendering on a
low-end phone and with two real players (O34); real ConfigService propagation for Codes,
shared-store throttling under production load, device accessibility preferences and audible
SoundGroup mixing; and, for the moderation kit, which real `BanAsync` errors are transient, the real
ban modal, alt propagation, device block, cross-server latency, real group ranks, voice mute through
`AudioDeviceInput` access lists, text mute (`TextSource.CanSend` isn't documented either way under
platform-integrated chat) and the staff panel on phones. Each is listed in `docs/manual-qa.md` under
"New in v1.8.0".

## Fixed ids (index)

Code comments, `CHANGELOG.md` and `docs/decisions.md` still cite some ids of issues that are fixed.
`N<n>` ids come from the v1.1.0 review, `R<n>` from later reviews.

| Id | Fixed in | What it was |
|---|---|---|
| N1 | v1.2.0 | A Mail handler that couldn't accept a message dead-lettered it; now it waits in the mailbox |
| N2 | v1.1.0 | A failed `PolicyService` lookup stayed unknown; now it is retried |
| N3 | v1.2.0 | Items registered later weren't added to odds already disclosed to clients |
| N4 | v1.2.0 | A paid roll could use luck the client hadn't been shown odds for |
| N5 | v1.1.0 | Copies rolled with a paid currency weren't tagged (`paidcur:`) and could be traded |
| N6 | v1.2.0 | Legacy mail messages without an id could be delivered twice |
| N7 | v1.1.0 | A boot that failed part-way left the framework half-usable |
| N8 | v1.2.0 / v1.3.0 | Read APIs returned live save tables that callers could mutate (now frozen views) |
| N9 | v1.2.0 | Receipts dropped when a player left were not reported |
| N10 | v1.1.0 | Mail tried to deliver to players who had already left |
| R1 | v1.3.0 | Gifts to a player who never returns could overflow ProfileStore's message queue (now capped per recipient, returned after 14 days) |
| R2 | v1.2.0 | A same-server gift bypassed the crash-safe outbox |
| R4, R5 | v1.2.0 | Paid-currency tables and table-wide luck could reach paid rolls without disclosure |
| R6, R7 | v1.3.0 | Dead letters couldn't be replayed on live servers; duplicate detection had a short window |
| R8, R13, R14 | v1.2.0 / v1.3.0 | Guardrail evasions (aliases, string tricks, neutral folders) |
| R10 | v1.3.0 | The rest of N8: frozen read views everywhere, not only in Studio |
| R15 | v1.2.0 | The mail payload hash wasn't real FNV-1a |
| R16 | v1.3.0 | A generator bug in `tools/new-game` |
| R19 | v1.3.1 | The framework still knew kit names and kit actions; now each kit is one folder with its own `net.blink` |
| R20 | v1.3.1 | A paid currency with no registered spender wasn't caught; now a boot error |
| R22 | v1.3.1 | `saveNow` didn't bump the `_framework` section version |
| V1 | v1.4.1 | The games-repo pre-commit hook failed the pin check on every commit |
