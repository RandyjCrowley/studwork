# Pending shared-file changes: the `quests` kit (v1.8.0)

Everything the `quests` kit would change in files this round may not edit (a parallel round builds
another v1.8.0 kit in the same repo). The integrator applies each section after merging both kits,
then deletes this file. Builders append under **Builder notes** at the end, never above it.

Framework files touched (builders list any here, with why):
- `packages/framework/server/init.luau` (wire): `rt.gameConfigPublic` gains `analytics =
  Freeze.freezeCopy(gameConfig.analytics or {})` (additive), so `ctx.gameConfig.analytics.funnel` is
  readable by modules. No public surface exposed `GameConfig.analytics` before (`ctx.analytics` is the
  logging api only), and Goals needs the list to warn about funnel steps it would never log. Spec:
  `packages/framework/test/Boot.spec.luau` ("ctx.gameConfig ... analytics" assertion; fails without it).
- Reverted: F1's `ctx.replicate.set` frozen-subtree reuse in `packages/framework/server/Replication/`
  (the orchestrator reverted it once perf2's flat wire shape made Quests independent of it; a framework
  follow-up, see known issue O21).

Other kits touched (F1 perf, with the orchestrator's brief): `packages/kits/engagement/Leaderboards/server/init.luau`
(one line: `signals` is `setmetatable({}, {})`) and `packages/kits/engagement/tests/Leaderboards.spec.luau`
(new `signals` describe; fails without it).

Edits outside the kit made on the branch with the orchestrator's OK (all by builder A; see sections
9 and 10): tool-generated `*.project.json` entries (`tools/sync-projects`, sandbox and templates
included), the `tools/lune/NewGame.spec.luau` count (15 -> 17), and the kit-owned bench variant
`tools/lune/bench/QuestsVariant.luau` with a separate additive block in
`tools/lune/bench/replication.luau`.

Also edited outside the kit (named here so the integrator sees them; details in the builder notes):
- `docs/framework/getting-started.md`: the `tools/make-module` example module is renamed from `Quests` to
  `Trophies` (a game module named `Quests` collides with the kit).
- `tools/test-single-game` and `tools/test-games-repo`: the fixture module `Missions` rename (it
  collided with the kit's module names).

## 1. `CHANGELOG.md` (under `## [Unreleased]`, `### Added`)

```markdown
- **Quests kit (`packages/kits/quests/`): Quests and Goals**, two normal kit modules on the public
  module API ([docs/framework/kits/quests.md](docs/framework/kits/quests.md)), each with a `flag`
  kill switch, working when a game leaves it out:
  - **Quests:** config-defined daily, weekly, story-chain, one-time, repeatable and event quests.
    Daily and weekly sets are dealt from a weighted pool deterministically per player per period
    (seed = user, period, pool version, slot, reroll index) and saved, so a rejoin or server hop
    shows the same set; one free reroll per daily slot per day (config). Periods follow the framework
    clock in `utcOffsetHours`. Objectives: counters (`progress`), thresholds and built-in sources from
    Economy, Inventory, Rebirth, Streak and Leaderboards signals, plus game-registered sources.
    Rewards: currency, items, free Rarity rolls at luck 1 whose odds the quest board shows, and game handlers; a claim and
    its grants are one transaction, so a reward is granted exactly once (double taps, save failures,
    shutdowns, rejoins on another server). Progress is batched in memory (no save write per
    increment) and safe to call inside a game's own transaction. Periods only move forward, so a
    server hop across the reset can't re-deal a set. Both modules boot with no config. A quest board
    screen, a HUD tracker for pinned quests and claim toasts, all theme-driven, localized and usable
    at 667x375 with touch and gamepad. No Robux.
  - **Goals:** the first-session goal chain and next-goal pointer: a HUD pill, one world beam toward
    the target and an off-screen edge arrow (StreamingEnabled-safe: last known position or a
    configured fallback), a game "what's next" after the chain, one analytics funnel step per goal.
    Never blocks input, never opens a screen or moves the camera. Works without Quests. Players who
    joined before a game added Goals start with the chain finished.
- `examples/quests-demo/`: a fixture game showing every Quests and Goals surface in Studio, with
  Studio-only console commands to force states.
- `tools/bench` variant `KITS-QUESTS`: KITS-ALL plus Quests and Goals, 50 players with 10 active
  quests progressed every tick.
```

Under `### Fixed`:

```markdown
- Leaderboards: `signals.BoardRefreshed` is reachable through the module's api
  (`StudWork.use(Leaderboards).signals.BoardRefreshed` was nil: the signals table was a plain table
  the framework copied before `init` created the signal).
```

## 2. `docs/decisions.md` (a new `v1.8.0: quests kit` section)

```markdown
## v1.8.0: quests kit

**Quests and Goals are two modules in one kit folder.** Goals is the first-session pointer and must
work in a game with no quest system; Quests is the retention layer. Splitting them keeps each
switchable (`modules`, `flag`) and lets Goals point at quests through Quests' public API only.

**One reset boundary per game, on the framework clock.** Days and weeks are counted as Streak and
Leaderboards count them: `floor((ctx.now() + utcOffsetHours * 3600) / 86400)`, weeks from
`weekStartsOn`. A per-player local day would need the client's clock, which a player controls, and
would let a server hop or clock change re-deal a set.

**The daily set is dealt deterministically and saved.** The saved set is authoritative for its
period; the seed (FNV-1a of user id, kind, period id, `poolVersion`, slot, reroll index; xorshift32
draw over the eligible pool in id order) only re-creates it when no saved set exists (new period,
or a crash rolled the save back). So rejoining, hopping servers or crashing can't fish for a better
set or a free extra reroll.

**Claim and grant in one `ctx.tx`.** The claim record (period/window, `done`, chain step) and every
reward grant (`Economy` / `Inventory` / `Rarity` txApi, or the game's registered handler) commit
together or not at all; the tx doesn't yield, one tx per player runs at a time, and the session lock
gives one writer across servers. This is the same reasoning as receipt-safe purchases, without
Robux.

**Progress is batched, and `progress` never opens a transaction.** A busy game calls `progress`
every frame; a save transaction per call would blow the tick budget. Non-completing increments stay
in memory and fold into the section every `foldSeconds` (staggered per player), before any
claim/reroll/deal, on leave and on shutdown. An increment that completes an objective flags the
player and is folded on the next 1-second tick, not synchronously: the framework allows one
transaction at a time and errors on a nested one, and games call `progress` from inside their own
transactions (a crate tx, a Mail claim, a reward handler). `Goals.complete` queues the same way. So a
crash loses at most `foldSeconds` of partial progress, or a completion from the last second.

**Periods only move forward.** Each server's `os.time()` differs by a few seconds, so near the reset
a player can hop from a server already on day D+1 to one still on D. A saved period id (and every
saved period or window key) is only ever replaced by a larger one; a set saved ahead of this
server's clock stays current. Otherwise the hop would re-deal day D from its seed and let its quests
be claimed twice.

**Both modules boot with no config.** `tools/new-game` and `tools/adopt --init` list every kit
module by default, with no config section for the new ones (`tools/test-adopt` boots that game in
the sim). So `daily.count` larger than the pool is an error only for a non-empty pool; an empty pool
deals nothing.

**Acknowledge objectives are the only client-driven progress.** A quest made only of `ack`
objectives, or auto-claimed with one, is a boot error; `ackQuest` / `ackGoal` are rate-limited
actions that never grant anything themselves.

**Random rewards go through Rarity at luck exactly 1, free, with odds Quests discloses itself.** The
claim passes `luck = 1` explicitly (Rarity's `nil` means the player's session luck). A quest claim
is not a purchase and spends no currency, so Compliance treats the roll as free; a table Rarity
counts as paid (`paid = true`, or a cost in a paid currency) is a boot error, because Rarity would
treat any roll on it as paid and refuse restricted players. Rarity replicates odds only for tables
with a cost or `luckDisclosed`, so Quests replicates `Rarity.getOddsDetail(table, nil, 1)` for every
roll-reward table (`extra.questOdds`), and every roll reward chip on the board has an Odds button
showing exactly those odds. PolicyService's `ArePaidRandomItemsRestricted` governs paid random items
only (https://create.roblox.com/docs/reference/engine/classes/PolicyService); no quest reward
involves Robux.

**One beam, attachments under Terrain.** A Beam renders only when it and both attachments are
descendants of Workspace (https://create.roblox.com/docs/reference/engine/classes/Beam,
https://create.roblox.com/docs/reference/engine/classes/Attachment,
https://create.roblox.com/docs/effects/beams); two attachments on `workspace.Terrain` need no extra
parts. The pointer updates on a budget (`pointer.updateSeconds`, and only after half a stud of
movement), and the edge arrow uses `Camera:WorldToViewportPoint`
(https://create.roblox.com/docs/reference/engine/classes/Camera).

**StreamingEnabled: point at what the client last saw.** A streamed-out instance is parented to nil
on the client (https://create.roblox.com/docs/workspace/streaming), so a tag or path target can be
missing. The client keeps each target's last known position, then a configured `fallback`, then hides
the beam and keeps the pill. `ModelStreamingMode.Persistent` is documented as an option for a few
small targets only, as Roblox recommends (same page; `Workspace.PersistentLoaded`:
https://create.roblox.com/docs/reference/engine/classes/Workspace). The server doesn't walk the world
for targets.

**Gamepad focus only inside a screen the player opened.** The board sets
`GuiService.SelectedObject` (https://create.roblox.com/docs/reference/engine/classes/GuiService) to its
first Claim button when opened from a gamepad; the pill, tracker and edge arrow are never
`Selectable`, so they can't steal the game's navigation. Reduce motion follows the framework's
`CoreReducedMotion` attribute or `GuiService.ReducedMotionEnabled`.

**Funnel steps through `ctx.analytics.funnel`.** The framework already logs each step once per player
(`AnalyticsService:LogOnboardingFunnelStepEvent`,
https://create.roblox.com/docs/reference/engine/classes/AnalyticsService); Goals adds no store of its
own. Tags for targets use CollectionService
(https://create.roblox.com/docs/reference/engine/classes/CollectionService).

**Removed ids are pruned on load, not by migrations.** Quest and goal ids come and go with content
updates; a migration per removal would be churn. `data.sanitize` has no config (`fn(section) ->
section`) and an error in it kicks the player, so it only repairs shapes; the config pruning runs in
each module's first tx on `onPlayerLoaded`. Quests' `done` ledger is never pruned, so a one-time
quest removed and re-added can't be claimed twice; `retired = true` is still the clean way to stop
offering one.

**Returning players skip the first-session chain.** When a live game adds Goals, a player whose
`goals` section is new but who has played before (`ctx.framework.sessions(player) > 1`) starts with
the chain finished and logs no funnel steps, so the onboarding funnel counts new players only.

**Event quests read events, they don't own them.** `ctx.events.schedule` allows one handler per event
id, which belongs to the game, so Quests uses `isActive` and the framework's `EventStarted` /
`EventEnded` signals. A hand-triggered event's window key is the start of its UTC day, so a server
hop can't open a second claim (and a second trigger the same day doesn't reopen a claimed quest).
```

## 3. `docs/known-issues.md`

```markdown
### O14. A server crash can lose up to 30 s of partial quest progress

Quests folds non-completing progress into the save every `foldSeconds` (default 30). A crash in
between loses that partial progress (never a completion or a claim). Lower `foldSeconds` to shrink
the window at some tick cost.

### O15. Goals can't check that funnel steps are listed

`ctx.analytics.funnel` drops a step that isn't in `GameConfig.analytics.funnel`. Goals logs a boot
**warning** per goal whose `funnel` step isn't listed (needs the framework change in "### docs2";
until that lands the page's claim of a warning is not yet true). Quests' per-quest `funnel` is not
checked. The kit page says to list every step.

### O21. Quests tick cost in the worst-case bench is over the v1.7.0 budget (accepted for v1.8.0)

**Accepted for v1.8.0.** `tools/bench` variant `KITS-QUESTS` is a stress case: KITS-ALL plus Quests and
Goals, 50 players each progressing all 10 active quests every bench tick (one `progress` call per
player per tick on a key shared by all 10 quests: 500 quest updates per tick), `replicateSeconds = 1`. It measures ~1.34 ms per tick against KITS-ALL's ~0.85 (budget 1.128).
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
```

(Ids follow the last O-number in `docs/known-issues.md`; renumber if the other kit's pending file
takes O14+ first.)

## 4. `docs/framework/module-reference.md`

Under "Config keys added in v1.7.0", add a sibling section:

```markdown
## Kit modules added in v1.8.0

`Quests` and `Goals` (`packages/kits/quests/`) are normal modules with their own `config.<Name>`
([quests](kits/quests.md)). `Quests.claim(player, questId) -> (boolean, reason?)` and
`Quests.reroll(player, kind, slot) -> (boolean, questIdOrReason)` return a reason on refusal;
`registerSource` / `registerReward` (Quests) and `registerSource` (Goals) are **extensions**, called
in `init` through `ctx.depsExt[...]`, because both modules validate their config in `start`.
```

## 5. `docs/framework/kit-contract.md`

Intro: "The fifteen built-in kit modules" becomes "seventeen" (plus the other v1.8.0 kit's count),
and the kit-page list gains a "Quests" link to `kits/quests.md`. New section before "Client side":

```markdown
## Quests kit

### Quests (v1.8.0)

- **api:** `progress(player, key, amount?) -> boolean` (batched; safe inside a tx), `claim(player, questId) -> (ok,
  reason?)`, `reroll(player, kind, slot) -> (ok, questIdOrReason)`, `active(player) -> { QuestView }`,
  `state(player, questId) -> QuestState?`, `def(questId) -> Quest?`, `grant(player, questId) -> (ok, reason?)` (server only),
  `pin(player, questId, on) -> (ok, reason?)`.
- **extensions:** `registerSource(name, { read, changed? })` (value sources), `registerReward(handler,
  fn(tx, player, params, questId))` (runs inside the claim tx).
- **signals:** `Progressed(player, questId, values)` (coalesced), `Completed(player, questId)`,
  `Claimed(player, questId, rewards)`, `Rotated(player, kind, periodId)`.
- **Uses:** Economy (`CurrencyChanged`, `balance`, `txApi.grant`), Inventory (`ItemAdded`,
  `ItemRemoved`, `list`, `cap`, `txApi.add`, `txApi.count`), Items (`get`), Rarity (`txApi.roll` at
  luck 1, `getOddsDetail`), Rebirth
  (`Rebirthed`, `count`), Streak (`StreakAdvanced`, `get`), Leaderboards (`BoardRefreshed`, `rank`), all
  optional and only when the config references them; `ctx.events.isActive`, framework signals
  `EventStarted`/`EventEnded`, `ctx.analytics`.
- **Replicated `extra`:** `board`, `prog` (per player), `questOdds` (shared). **Save section:**
  `quests`, not replicated.
- **Client:** `active()`, `board()`, `onCompleted(fn)`, `onClaimed(fn)`, `open(tab?)`; actions
  `claimQuest`, `rerollQuest`, `pinQuest`, `ackQuest`; screen `"Quests"`; widgets `"Quests.tracker"`,
  `"Quests.button"`.

### Goals (v1.8.0)

- **api:** `current(player) -> GoalView?`, `complete(player, goalId) -> (ok, reason?)` (queued; safe inside a tx),
  `setChain(chain, version?)`, `setNext(fn(player) -> NextGoal?)`, `skip(player, hidden) -> boolean`.
- **extensions:** `registerSource(name, { read, changed? })`.
- **signals:** `GoalChanged(player, goalId?, previousId?)`, `ChainDone(player)`.
- **Uses:** Quests (`def`, `state`, `Completed`, `Claimed`, `Progressed`), Economy, Inventory, Rebirth, Streak
  (value sources), all optional; `ctx.analytics.funnel`, `ctx.framework.sessions`.
- **Replicated `extra`:** `goal`. **Save section:** `goals`, not replicated. **Theme:** `colors.goalPointer`.
- **Client:** `goal()`, `pointer()`, `onChanged(fn)`, `registerPicker(name, fn)`, `setHidden(hidden)`;
  actions `skipGoals`, `ackGoal`; widget `"Goals.goal"`.
```

In "Client side", add `"Quests.tracker"`, `"Quests.button"` and `"Goals.goal"` to the widget list and
`"Quests"` to the screens.

## 6. `docs/framework/module-api.md`

No API change (no new `ctx` service, no framework event). Optional pointer in §16's kit table:

```markdown
| **quests** | Quests, Goals | v1.8.0 kit modules; nothing in the framework names them (link: `kits/quests.md`) |
```

## 7. `--modules`: `tools/lune/KitModules.luau`, `tools/new-project`, `tools/new-game`, `templates/`

- `tools/lune/KitModules.luau` `ORDER`: add `"Quests"` and `"Goals"` after `"Notifications"` (until
  then they sort last alphabetically, which works). `tools/lune/NewGame.spec.luau`'s
  `#Modules.ORDER` count follows the module total (see section 10).
- `templates/new-game/src/shared/Config/init.luau` `modules`, after the Notifications line:

```lua
		require(Modules:WaitForChild("Quests"):WaitForChild("module")), -- daily/weekly/story quests, exactly-once claims, board + tracker
		require(Modules:WaitForChild("Goals"):WaitForChild("module")), -- first-session goal chain: HUD pill + one arrow to the next goal
```

- `templates/new-game/src/shared/Config/Balance.luau` (dropped by a `--modules` list without them,
  like the v1.7.0 sections; `Quests` references Economy only, which the template has):

```lua
	Quests = {
		daily = { count = 3, rerollsPerSlot = 1 },
		weekly = { count = 2, rerollsPerSlot = 0 },
		quests = {
			earnCoins = { kind = "daily", objectives = { { kind = "source", source = "currencyEarned", target = 500 } },
				reward = { { kind = "currency", amount = 100 } } },
			playMinutes = { kind = "daily", objectives = { { kind = "counter", key = "minutePlayed", target = 5 } },
				reward = { { kind = "currency", amount = 75 } } },
			collectThings = { kind = "daily", objectives = { { kind = "counter", key = "collected", target = 20 } },
				reward = { { kind = "currency", amount = 120 } } },
			earnBig = { kind = "weekly", objectives = { { kind = "source", source = "currencyEarned", target = 20000 } },
				reward = { { kind = "currency", amount = 2000 } } },
			returnDays = { kind = "weekly", objectives = { { kind = "counter", key = "dayPlayed", target = 3 } },
				reward = { { kind = "currency", amount = 1500 } } },
		},
	},
	Goals = {
		chain = {
			{ id = "firstCoins", check = { source = "currency", atLeast = 25 } },
			{ id = "firstQuest", check = { quest = "earnCoins" } },
		},
	},
```

- A `--modules` list with `Goals` but without `Quests` drops the `firstQuest` goal (its check needs
  Quests; boot validation would refuse it).
- The game module's `optional` gains `Quests` and `Goals` (moved to `dependsOn` when named in
  `--modules`, like the v1.7.0 kits); `GameConfig.analytics.funnel` gains `"FirstCoins"` if goals log
  funnel steps.
- `docs/framework/generators.md`: add Quests and Goals to the `--modules` paragraph and the list of
  generated config sections; the template-matrix sentence gains `Quests`, `Goals`.
- `tools/new-project` / `tools/new-game`: no code change expected (they read `KitModules`); if their
  help text lists modules, add the two names.

## 8. `examples/sandbox` wiring

`src/shared/Config/init.luau` `modules`: the two `require` lines above. `Balance.luau`:

```lua
	Quests = {
		daily = { count = 3, rerollsPerSlot = 1 },
		quests = {
			sandboxCoins = { kind = "daily", objectives = { { kind = "source", source = "currencyEarned", target = 300 } },
				reward = { { kind = "currency", amount = 100 } } },
			sandboxHatch = { kind = "daily", objectives = { { kind = "source", source = "itemCollected", target = 2 } },
				reward = { { kind = "roll", table = "Basic" } } },
			sandboxRebirth = { kind = "oneTime", objectives = { { kind = "threshold", source = "rebirths", target = 1 } },
				reward = { { kind = "currency", amount = 1000 } } },
			sandboxTicks = { kind = "daily", objectives = { { kind = "counter", key = "tick", target = 60 } },
				reward = { { kind = "currency", amount = 50 } } },
		},
	},
	Goals = { chain = { { id = "sandboxFirstCoins", check = { source = "currency", atLeast = 50 }, funnel = "FirstCollect" } } },
```

(Use a Rarity table id the sandbox has; `FirstCollect` must be in its `analytics.funnel`.) The
sandbox's `foundation-only.project.json` needs nothing (`modules = {}`). `LeaderboardsDemo`-style
spec: optional `QuestsSandbox.spec.luau` in `examples/sandbox/src/shared/` (boots, quick claim).

## 9. Bench (`tools/lune/bench/replication.luau`)

The variant list is in this shared file. The kit's variant lives in its own file,
`tools/lune/bench/QuestsVariant.luau` (modules, config, per-tick work), and `replication.luau` gets
**one separate block, appended right after the `local ORDER = { ... }` line** (builder A applies it,
with the orchestrator's OK). It changes no existing line: not `bootKits`' signature, not `ORDER`'s
literal, so the other kit's block merges next to it without a conflict:

```lua
-- (v1.8.0 quests kit) KITS-QUESTS: KITS-ALL + Quests + Goals, 50 players x 10 quests progressed per tick
local QuestsVariant = require("./QuestsVariant")
variants["KITS-QUESTS"] = function(players)
	return QuestsVariant.boot(players, bootKits, Harness) -- wraps the harness constructor for this one call
end
tickFns["KITS-QUESTS"] = function(p: FakePlayer, tick: number)
	QuestsVariant.tick(runtimes[p].player, tick)
	tickFns["KITS-ALL"](p, tick)
end
table.insert(ORDER, "KITS-QUESTS")
```

`QuestsVariant.boot(players, bootKits, Harness)` temporarily replaces `Harness.mapGame` with a
wrapper that calls the original and then wraps the fresh facade's `StudWork.test.harness` so the
`opts` gain the Quests and Goals definitions and config; it calls `bootKits(players, true)`, restores
both, keeps the harness `h` it saw (for `h:use(Quests)`), and returns `bootKits`' sync function. If
the facade's `test` table can't be wrapped, builder A stops and asks the orchestrator before touching
`bootKits`.

Budget line for `tools/bench`'s header and CLAUDE.md "Definition of done" (integrator):
"KITS-QUESTS (KITS-ALL + Quests + Goals, 10 quests progressed per player per tick) <= 1.2 x the same
run's KITS-ALL median".

## 10. Tool-generated or count edits outside the kit (applied on the branch, regenerate on merge)

- Every `*.project.json` under `examples/` and `templates/` (sandbox and template included) gains the
  generated `Modules.Quests` / `Modules.Goals` entries: `tools/sync-projects` writes them for every kit
  module folder, and `tools/lint` (`sync-projects --check`) fails without them. **Only the tool edits
  these files.** On a merge conflict with the other kit, take either side and re-run
  `tools/sync-projects`.
- `tools/lune/NewGame.spec.luau`: `expect(#Modules.ORDER).toBe(15)` becomes 17 (15 + this kit's 2; add
  the other kit's count at merge). Orchestrator-approved (Q2).
- The project-file regeneration above is orchestrator-approved (Q1): builder A runs
  `tools/sync-projects` once (tool output only, sandbox and templates included) and the integrator
  re-runs it at merge.
- Default boots (checked): `tools/adopt --init` with no `--modules` uses `Modules.ORDER`
  (`tools/lune/adopt-init.luau`), and `tools/test-adopt` boots that game in the sim with the minimal
  adopt config (no `Quests`/`Goals` section); `tools/new-game` with no `--modules` also lists every
  module. Both modules therefore boot with no config (kit page, "Config validation").
- `examples/quests-demo/` is new (owned by this kit); `tools/build --all`, `tools/typecheck --all` and
  `tools/sync-projects` find it as `examples/<game>/default.project.json` + `src/`; serve port 34960.

## 11. Indexes and the live checklist

- `docs/framework/README.md` / `docs/README.md` kit index: add a "Quests and Goals" link to `kits/quests.md` (relative to the index file).
- `docs/framework/getting-started.md` / `override-levels.md` if they list kit modules: add the two.
- `CLAUDE.md` folder map: `quests: Quests Goals` in the kits line.
- `docs/manual-qa.md`, "New in v1.8.0 (quests)":

```markdown
- [ ] Quest board on a phone (Device Emulator 667x375 and a real device): tabs, rows, Claim,
      Reroll, Odds, "Resets in"; text readable; nothing clipped; touch only.
- [ ] Gamepad: open the board from the HUD button, first Claim selected, B closes; the pill, tracker and
      edge arrow never take focus.
- [ ] Goal pill and beam in the first session: they help without nagging; no modal, no camera move;
      reduce motion on: no pulse.
- [ ] StreamingEnabled place: a goal target far away (streamed out) still gets an edge arrow (last
      known or fallback); walking toward it streams it in and the beam snaps to it.
- [ ] Reset time: a daily set changes at the configured local midnight for players in your main time
      zone; the set is the same after rejoining and after joining another server.
- [ ] Save size after weeks: `data dump <userId>` for a regular player: the `quests` section stays a
      few KB (no per-day growth).
- [ ] A claim with full inventory shows the refusal toast and keeps the quest claimable.
- [ ] A roll reward's Odds button shows the table's odds at luck 1, also while the player has a luck
      boost.
- [ ] At 667x375 the Goals pill, the currency widget, the mailbox and `Game.nextGoal` (if used) don't
      overlap in `topCenter`.
```

## Deferred review findings (v1.8.0 design review)

- **L1** (`currencyEarned` reason filter): a new `params` field is a new surface; documented as
  O18 above. Revisit with a `params.reasons` allow/deny list when a game needs it.

## Builder notes

(Each builder appends a `### <builder>` subsection here: shared-file changes they found necessary,
with the exact text.)

### A foundation

Applied on `feature/v1.8-quests-foundation` (regenerate or re-apply at merge):

- **Project files (tool output only):** `tools/sync-projects` added the `Modules.Quests` /
  `Modules.Goals` entries to every `*.project.json` under `examples/` and `templates/` (section 10,
  Q1). On a conflict with the other kit, take either side and re-run the tool.
- **`tools/lune/NewGame.spec.luau`:** `expect(#Modules.ORDER).toBe(17)` (section 10, Q2; add the
  other kit's modules at merge).
- **Bench hook (`tools/lune/bench/replication.luau`):** the block of section 9, verbatim, after the
  `local ORDER` line. `QuestsVariant.boot` works as planned with one detail: the facade's
  `StudWork.test` is frozen, but its `harness` is a forwarder that looks up the test kit's
  `Public.harness` (a plain table, cached by path) at call time, so the variant wraps
  `Harness.mapGame` and, right after the game is mapped, `Public.harness`; both are restored after
  the one `bootKits(players, true)` call. `bootKits` and `ORDER`'s literal are unchanged.
- **`tools/test-single-game`, `tools/test-games-repo` (outside the A row; needs the orchestrator's
  OK):** both scaffolded a game-local module with `tools/make-module Quests`, which now collides with
  the kit module `Quests` (`ReplicatedStorage.Modules.Quests` is the kit's; the game module's client
  `require` fails typecheck: "Unknown require"), so both tools failed. The fixture is renamed
  `Missions` (3 lines + the commit message in one, 2 lines in the other). Suggested follow-up (not
  done): `tools/make-module` could refuse a name that a kit module already uses.

Deviations from the design plan (the kit page wins):

- `net.blink` arguments are tuples, as in the page's Actions table and every other kit:
  `RerollQuest` `Data: (SlotKind, u8)` with `enum SlotKind = { daily, weekly }`, `PinQuest`
  `Data: (QuestId, boolean)`; handlers get `(player, kind, slot)` / `(player, questId, on)` and
  `h:action(p, Quests, "rerollQuest", "daily", 1)` works. The plan wrote them as `{ kind, slot }`.

Notes for the builders (shapes in place; replace the hook bodies, keep the wiring):

- Server stubs: `Quests/server/init.luau` and `Goals/server/init.luau` have a "Hooks" section
  (`onLoaded`, `onRemoving`, `onShutdown`, `onTick`, `onFlagChanged`, `onEventStarted/Ended`,
  `onDepSignal(module, signal, args)`, `onSourceChanged`, `onAck`; Goals: `markDirty`, `onAck`,
  `reset`) already connected to the lifecycle, the 1 s tick, the flag, the framework event signals,
  the dependency signals the config references, registered sources' `changed`, and the console.
  `def` is real (`shared/Validate.defs`); `quests timeshift` already shifts the module clock
  (`now()` in the Quests server part: use it, not `ctx.now()`, for periods). Quests already sets
  `extra.questOdds` at start (luck-1 details of every roll reward's table). Goals' `setChain` /
  `setNext` store and validate for real.
- `Quests/shared/Validate.SOURCES` holds every built-in source's mode, needed modules and
  required param; `Goals/shared/Validate.SOURCES` the four value sources.
- Fixtures (`tests/Fixtures.luau`): config builders for every quest kind (`F.questsConfig()` has one
  of each), `F.valueSource` / `F.rewardModule` probe modules (register through the real
  extensions in init; the reward handler writes only its own section), `F.signal`, `F.harness`.
  `tests/FakeState.luau`: a real Charm atom with `board/prog/odds/goal` setters and `fs:start()`,
  which boots the client runtime with that state and records every action fired (`fs.fired`).
- Goals' pill is `topCenter` order 3, the same slot and order as Mail's `Social.mailbox`; the
  Studio 667x375 check covers it, but the Goals builder may want a different order.
- `tools/new-game` / `adopt --init` list the two modules after the 15 (they sort last, Goals before
  Quests) until `KitModules.ORDER` gains them (section 7). Goals validates `quest` checks in its
  `start`, after every module's `init` (where Quests builds its `def` table), so either order boots.
- The demo (`examples/quests-demo`) builds its world only where `CollectionService.AddTag` exists
  (Studio, live); in Lune specs and the sim the game module logs one info line instead, so the sim
  boot has no warning. Its client sends `ackGoal("openBoard")` when the `Quests` screen opens while
  that is the current goal (`UI.screens:subscribe`).

### B Quests server

Built on `feature/v1.8-quests-quests`: `Quests/server/init.luau` (real), `Quests/server/Model.luau`
(the section rules: deal, pruning, claim lookup, states), `Quests/shared/Deal.luau` (the pinned
deal), the B specs (`tests/Quests{QuickStart,Deal,Progress,Claims,Rotation,Rerolls,Sources,Rewards,
Events,Skew,Save,Console}.spec.luau`, helper `tests/QuestsKit.luau`) and the two gate sims
(`tests/QuestsClaimSim.spec.luau`, `tests/QuestsResetSim.spec.luau`). No shared file, framework file
or other kit was edited.

**Bench (design-plan Q10, budget KITS-QUESTS <= 1.2 x KITS-ALL): not met.**
`tools/bench 5 KITS-ALL KITS-QUESTS`, three runs while the other round ran:

| run | KITS-ALL | KITS-QUESTS | ratio |
|---|---:|---:|---:|
| first working build | 0.906 | 2.378 | 2.62 |
| after the hot-path work | 0.821 | 2.024 | 2.47 |
| rerun | 0.834 | 2.123 | 2.55 |
| ablation: `extra.prog` not replicated (not committed) | 0.877 | 1.419 | 1.62 |

About half the extra cost is the framework replicating `extra.prog` (50 players x 10 changed arrays
per tick): `ctx.replicate.set` deep-copies every table value (`Snapshot.copy`), so the kit's
identity reuse of unchanged arrays never reaches charm-sync, and the copy plus the diff cost
~0.6 ms/tick. The rest is the kit's own per-call work (progress ~0.15 ms, the live-value send
~0.2 ms incl. the coalesced `Progressed` signal, folds ~0.08 ms per tick in a harness profile).
Options for the orchestrator: accept a higher KITS-QUESTS budget for this worst case (every player
progressing 10 quests every tick); or a small additive framework change, `ctx.replicate.set`
reusing the last copy of frozen subtrees (`Snapshot.copyShared`, already used for `data`), which
makes the page's "only quests that changed get a new table" true on the wire.

(Leaderboards' unreachable `BoardRefreshed`, first noted here as O20, is fixed on the branch: see F1 perf.)

Behaviour the page leaves open, decided in the code (for the decisions entry):

- `state(player, id)` is nil for an unknown id and also for an unloaded player or while the flag is
  off; `active()` is empty then.
- `requires.quests` is met by a claim recorded in `done` (oneTime and chain steps).
- A retired chain step is skipped; a retired oneTime/repeatable/event quest is never active
  (`grant` refuses it with `"locked"`); retired daily/weekly quests already dealt stay until their
  period ends.
- `Rotated` fires when a set with at least one slot is dealt; a player with no pool for that kind
  gets no write and no signal.
- The deal pool snapshot (`seen`) is also the refill pool for a removed quest's unclaimed slot.
- An event that is active but whose `EventStarted` this server didn't see uses the UTC-day key (what a
  hand-triggered window uses); scheduled windows are started by the framework after every module's
  `start`, so this only matters for a module restarted mid-event.
- When an event window ends with its quest complete and unclaimed, the entry moves to `waiting` and
  the window stays consumed (`prog.s = 2`), so a server still inside the same window can't reopen it.
- `pin(player, id, false)` for a quest that isn't pinned succeeds (nothing to do).
- A built-in source is re-read only on its module's signal (the page names no poll for them); if a
  module doesn't expose the signal, Quests logs a warning at start and reads that source on load and
  rebuild only (F1 perf).

### C Goals

Applied on `feature/v1.8-quests-goals`: only the C row (`Goals/server/**`, `Goals/client/**`,
`tests/Goals*.spec.luau`, `examples/quests-demo/src/server/FirstMinutes.spec.luau`) plus two new
helper files of my own, `tests/GoalsHelpers.luau` and `tests/GoalsClientEnv.luau`. No shared or
framework file touched.

For the orchestrator:

- **Pill order:** `"Goals.goal"` is `topCenter` **order 4** (`Economy.currency` 1, `Game.nextGoal` 2,
  `Social.mailbox` 3; no other widget uses `topCenter`). The kit page, Goals "Client part", says
  "order 3": change it to 4. `Pointer.spec.luau` checks the order against the three others.
- **`tests/FakeState.luau` (A) doesn't run under Lune:** its top-level Charm `require` fails (the
  Wally Charm package has no `init.luau` where the testkit maps it), and `Runtime.defaultLoadClient`
  binds the generated Blink `Net`, which needs `RunService`. The Goals client specs and the gate sim
  use `tests/GoalsClientEnv.luau` instead (plain-table state, client parts loaded without `Net`,
  fake UI kit, camera, GuiService, CollectionService). D or A may want the same two fixes in
  FakeState.
- **`FirstMinutes.spec.luau` has a TEMPORARY guard** (7 lines, marked): while Quests is the
  foundation stub (every claim `"not_loaded"`), the first-session `it` returns early. With the
  Quests server merged it never triggers (an unknown id answers `"unknown_quest"`); remove it at the
  round merge. Verified on a scratch merge of goals + quests + ui (`028302d` + `3cf5885` +
  `d036988`): `tools/test packages/kits/quests examples/quests-demo` 27 files, 259 tests, 0 failed;
  the first-session sim runs in full (every step once, chain handed to `game.next.dailies`, no
  warning, no error).

Behaviour the page leaves open (decided in code; add to decisions if wanted):

- `complete` for a player who has **finished** the chain returns `(false, "done")` (no funnel steps
  for veterans or after a chain change).
- An empty chain or a flag that is off **writes nothing** (`v` stays 0), so the returning-player
  rule still applies when a game adds a chain later. A flag turned on later runs the load step then.
- A save whose every chain goal is already done (the chain shrank) becomes `fin = true` in the load
  tx and fires `ChainDone` once, with no funnel steps.
- `setNext` answers are copied wire-safe: `text` 1..200 characters, `args` values string / number /
  boolean only, `target` one of the four forms, `widget` a string; anything else is dropped (an
  invalid answer counts as nil). The provider runs on load (past the chain), at the hand-over, when
  `setNext` is called again, and for players marked dirty by a relevant signal; never on a timer
  alone.
- The edge arrow is an `ImageLabel` with no image (the `theme` lint refuses asset ids in client
  code): a `goalPointer`-coloured circle with a rotated square tip, outline from the theme.

Suggested known issue (`docs/known-issues.md`):

### O20. The next-goal provider re-runs only on a relevant signal

Past the chain, `Goals.setNext`'s provider runs on load, at the hand-over and when one of the
signals Goals listens to fires (Quests, Economy, Inventory, Rebirth, Streak, registered sources),
at most once per `nextSeconds`. An answer that depends on something else (time of day, a game
value with no signal) updates on the next such signal. Register a source with a `changed` signal
for it, or call `Goals.setNext` again to refresh everyone.

Not covered offline: the pill's React render (known issue U5), the beam and edge arrow on a device,
`topCenter` at 667x375 next to the currency counter (Studio block).
### D Quests client UI

No shared file changed. Edits outside my files: none. Notes for the orchestrator and the merge:

- **`tests/FakeState.luau` can't load under Lune.** It requires `ReplicatedStorage.Packages.Charm`,
  and the Lune harness refuses the package (`charm/` has no `init.luau`: `src/init.luau` is Rojo-mapped).
  The client specs use their own `tests/QuestsClientKit.luau` (a plain state table, same `fired`
  recording, the part loaded directly because the generated `client/Net.luau` can't load under Lune
  either). Goals' client specs that use `FakeState` will hit the same wall; the fix is a tiny
  atom stand-in in `FakeState.new` (a function returning the current state) like `Runtime.spec` does.
- **Charm is optional in the part.** `Quests.start` subscribes to the state with Charm when it loads;
  `Quests.check` is the same watcher, called by hand by specs. It is a part field, not part of `api`.
- **Wire assumptions to confirm with the Quests server builder** (the page doesn't pin them):
  `board.list[i].s` and `slots[i].s` read as 0 active / 1 complete / 2 claimed, any other number as
  `"locked"`; `list` entries of kind `event` carry no `endsAt` (no "Resets in" on the Event tab);
  `rerollsLeft = rerollsPerSlot - slots[i].r`, from the client's config (a game that sets `daily.rerollsPerSlot`
  through an override reads the same value the server does because the client part gets the validated config).
- **Views add one objective field to `QuestView`: `label`** (the objective's string key), copied from
  config, so `active()` on the client can render the same lines the board does.
- **`onClaimed`** fires when a quest's status turns claimed, when a repeatable's `claims` goes up, or
  when a `waiting` entry leaves the list. A waiting entry dropped by `waitingMax` also looks like a claim.
- **Toasts** use `UI.ToastHost` in its own ScreenGui (`QuestsToasts`, DisplayOrder 50), created on the
  first toast. The kit toast animates on its own: reduced motion applies to the quest views (the
  progress bars jump instead of tweening), not to `UI.Toast`.
- **Reduced motion** follows the framework's convention (`CoreReducedMotion` player attribute or
  `GuiService.ReducedMotionEnabled`).
- **Checks left for Studio (667x375):** the board modal fit with 3 rows and a roll chip, the tracker
  and button stacking in the `right` slot with other widgets, gamepad selection on open, B closing,
  the Odds screen drawing over the board.

### F1 perf

Applied on `feature/v1.8-quests-perf`: `Quests/server/init.luau`, `tests/QuestsProgress.spec.luau`
and `tests/QuestsSources.spec.luau`, plus the framework and Leaderboards files listed at the top.

- **Cadence:** with `replicateSeconds` R > 1 each player's `extra.prog` sends sit on its own grid
  (phase `userId % ceil(R)`, step R), so sends spread over the ticks instead of landing on one;
  two sends to one player are always at least R apart, and R <= 1 behaves as before. The prog map is
  frozen, so (with the framework change) only the arrays that changed are copied and diffed.
  `progress` checks its player argument only when it isn't a loaded player (no pcall per call).
- **Leaderboards:** `BoardRefreshed` now reaches Quests, which re-reads `leaderboardRank` on it. The
  poll fallback for built-in sources is gone (the page names none); the known-issue text first
  written as O20 in the B section is dropped.
- **Bench (`tools/bench 5 KITS-ALL KITS-QUESTS`, the other round running): budget not met.** Default
  config (R = 1): KITS-ALL 0.870 / 0.873 / 0.930, KITS-QUESTS 2.347 / 2.325 / 2.235 (ratio about
  2.5). With R = 1 every player sends every tick and, in this variant, all 10 quests change every
  tick, so staggering and identity reuse can't remove any of the 500 changed arrays per tick. The
  framework copy and diff of those arrays plus the `Progressed` fires are about 0.9 ms; the floor
  without any sends is about KITS-ALL + 0.45 ms (progress 0.15, Goals' onTick 0.13, folds 0.09 per
  tick, measured with temporary os.clock totals). Measured, not committed, with the bench's
  `replicateSeconds` raised: R = 2: 0.833 / 1.720 (2.07x); R = 3: 0.913 / 1.638 (1.79x);
  R = 5: 0.928 / 1.459 (1.57x). So no cadence reaches 1.2x in this worst case: the remaining cost is
  Goals (outside F1's files), the framework tx per fold and the per-call progress work. In a game where
  a progress call moves one or two quests, the frozen map now sends only those arrays.

### F2 client

- **Event end time (changed):** the server sends no `endsAt` on `list` rows (`board.list` is `{ q, s, k?, cap?, p? }`).
  The client now reads an event quest's end from the framework's `state.framework.activeEvents[def.event]`
  (`{ [eventId] = endsAt }`), so the Event tab shows "Resets in". Without the event active there is no row anyway.
- **Rerolls left:** the client clamps `rerollsPerSlot` to the server's 0..3 ceiling.
- **Verified against the real server** (`tests/QuestsIntegration.spec.luau`, harness `h:state(p)` through the
  client readers): statuses 0/1/2, board order, rerolls and pins, chain step, repeatable `k`/`cap` (capped = claimed),
  waiting rewards after a reset, event rows, `questOdds`, empty board with the flag off; `onCompleted` once, `onClaimed`
  once, nothing for the first state or for a reset moving a quest to waiting.
- **`tests/FakeState.luau` removed:** nothing used it (Quests specs use `QuestsClientKit`, Goals `GoalsClientEnv`);
  it could not load under Lune (Charm). Stale mentions of it in earlier notes above are history.

### perf2

Applied on `feature/v1.8-quests-perf2`: `Quests/server/init.luau`, `Quests/client/State.luau` (+ spec),
`Goals/server/init.luau`, `tests/QuestsProgress.spec.luau`, `tests/QuestsQuickStart.spec.luau`, the new
`tests/GoalsDirty.spec.luau`, and one fixture line in `tests/QuestsClientApi.spec.luau` (the new wire shape).
No framework file. `replicateSeconds` stays `1` (the config defaults are unchanged).

- **`progress` is O(1) per call:** a counter amount goes to a per-key accumulator while no objective on
  that key can reach its target (the smallest amount left among the key's live objectives); the
  amounts are spread over the objectives before anything reads pending progress (a live read, a tx, a
  rebuild, a period change). A call that reaches a target takes the exact per-objective path (clamped,
  completion flagged and folded on the next tick, as before).
- **Wire shape (contract change):** `extra.progIds = { questId }` (sorted; sent only when the set of
  tracked quests changes) and `extra.prog = "v,v;v"` (per quest of `progIds`, in order, its live values
  joined by `,`, the quests by `;`). A string is copied and diffed as one value, where a table per quest
  cost the framework a copy and a walk per send. Nothing is sent when nothing moved. Flag off:
  `progIds = {}`, `prog = ""`. The client's `State.prog(state)` decodes the pair to `{ [questId]: { number } }`.
- **`Progressed(player, questIds: { string })` (contract change):** one fire per send (at most once per
  player per `replicateSeconds`) with the ids whose live values moved; read values with `Quests.state`.
- **Goals:** a signal marks a player only when it can change one of the player's not-done goals
  (`Completed`/`Claimed`: a goal on that quest; `Progressed`: an objective goal on a moved quest;
  `CurrencyChanged`: the new balance reaches an open currency goal's `atLeast`; the others: a goal on
  their source). Past the chain every signal still marks the player (the `setNext` provider). Kept per
  player and forgotten after every Goals write.
- **F1's framework change (`ctx.replicate.set` reusing frozen subtrees) is no longer needed by Quests**
  (`prog` is a string; `progIds` is set only when it changes). It still stands on its own merits.
- **Stale text elsewhere in this file** (apply at merge), in "Quests (v1.8.0)":
  - signals: replace `Progressed(player, questId, values)` (coalesced) with
    `Progressed(player, questIds)` (once per live-values send);
  - Replicated `extra`: replace `board`, `prog` (per player) with `board`, `progIds` and `prog` (per player).

  The F1 bench numbers above are superseded by the table below.

**Bench (`tools/bench 5 KITS-ALL KITS-QUESTS`, the other round running): budget not met.** Default config:
KITS-ALL 0.902 / 0.906, KITS-QUESTS 1.423 / 1.429 (was 2.393 at the start of perf2; ratio 2.66 -> 1.58).
Measured, not committed, with the bench's config changed:

| config | KITS-ALL | KITS-QUESTS |
|---|---:|---:|
| `replicateSeconds` 2 | 0.922 | 1.289 |
| `replicateSeconds` 3 | 0.881 / 0.872 | 1.232 / 1.233 |
| `replicateSeconds` 5 | 0.903 | 1.198 |
| `replicateSeconds` 3, `foldSeconds` 60 | 0.881 | 1.203 |
| `replicateSeconds` 5, `foldSeconds` 120 | 0.876 | 1.139 |
| Quests + Goals present, no `progress` calls | 0.899 | 0.995 |

The floor (profile, ms per bench tick, default config): Quests and Goals merely being present ~0.10
(the framework's per-flush snapshot and diff of two more modules' `extra` for every player Economy
dirties each tick, Goals' `CurrencyChanged` handler, GC); folds 0.09 (1.7 fold txs per tick, ~52 µs
each, ~40 µs of it the framework's section copy, share and freeze); `progress` 0.05 (50 calls, ~0.4 µs
of each the api wrapper); live-value sends ~7 µs each (build 3.5, set 0.8, Progressed 0.5, flush and
diff ~2.5) = ~0.35-0.4 at 50 sends per tick. So 1.128 ms (KITS-ALL + ~0.23) is out of reach for this
worst case within the kit: presence + folds + progress alone are ~0.24.

### docs2

Dogfood fixes (docs and shared Goals files). Page: `docs/framework/kits/quests.md`.

- **`--modules` lines (manual step until applied).** Section 7's `KitModules.luau` `ORDER` change is what
  makes `tools/new-game --modules` and `tools/new-project --modules` accept `Quests`/`Goals`; until then a
  game adds the kit by hand, and the kit page's "Add Quests and Goals to an existing game" says so. Once
  applied, change that section's lead sentence to "`--modules` includes the kit" and keep steps 2-3
  (game module `dependsOn`, `Boot.spec` `EXPECTED`) only for games made earlier.
- **getting-started:** the `make-module` example is now `Trophies` (a game module named `Quests`
  collides with the kit).
- **Template change (`Game.nextGoal` vs the Goals pill).** `templates/new-game/src/client/Main.client.luau`
  passes `nextGoal` to `Client.Hud.mount` inside `-- @if Economy,Rebirth`. With Goals chosen in
  `--modules`, the generator should drop that `nextGoal = function(): string? ... end,` entry and the
  locals only it uses (`rebirthCost`, `economy`/`EconomyDef`, `PRIMARY`), which would otherwise fail
  selene's unused-variable lint; without Goals nothing changes. Cheaper alternative: with Goals chosen,
  write `["Game.nextGoal"] = false` (a commented example already sits in `Config/init.luau`) uncommented.
- **Framework change needed for the funnel warning (not made here):** `packages/framework/server/init.luau`
  `rt.gameConfigPublic` (~line 708) gains `analytics = Freeze.freezeCopy(gameConfig.analytics or {})`
  (additive; or only `funnel`). Then Goals' server part, after `validate` succeeds in `start` (and in
  `setChain`), does: `for _, w in Validate.warnings(chain, ctx.gameConfig.analytics and
  ctx.gameConfig.analytics.funnel) do ctx.log.warn(w) end`. `Validate.warnings` is done and specced
  (`GoalsValidate.spec.luau`); with `funnel == nil` (older framework) it returns `{}`.
- **Goals client/server change needed for named positions (not made here; `Validate` already accepts both):**
  `Goals/server/init.luau` `wireTarget` (line ~96) must send `Validate.toArray(t.position)`, not
  `{ t.position[1], t.position[2], t.position[3] }` (a named position would send three nils);
  `Goals/client/Resolve.luau` `vec` (line ~64) must read `t[1]/t[2]/t[3]` or `t.x/t.y/t.z`
  (it's also used on `def.fallback`, which the client reads raw from config). Needs a spec in each
  (a named `target.position` and `fallback` resolve to the same Vector3 as the array form).
- **Types:** `Goals/shared/Types.luau` exports `ArrayPosition`, `NamedPosition`, `Position` (union)
  and `Chain = { Goal }`. A mixed chain annotated `GoalTypes.Chain` typechecked in a scratch copy of
  the demo's `Balance.luau` (position target named, fallback array); not committed.
- **Strings:** the page's "String keys and namespaces" section: own text is `game.*`; keys in a kit's
  namespace that nobody defines are an unknown-key warning.
- **Known-issues:** O15 above is reworded for the warning.

### ui2

Client UI fixes from the Studio run (files: `Quests/client/{init,Board,Row}.luau`, `Goals/client/{Pill,Resolve}.luau`,
specs in `tests/QuestsClient*`, `tests/QuestsUiFit.spec.luau`, `Goals/client/Resolve.spec.luau`).

- **Board size:** `UI.Modal` now gets no `size`. A given size turns its AutomaticSize off, and `fromScale(0.85, 0)` left
  a 0-high body that hung the panel off-screen. Modal's own default (0.6 of the screen wide, 320-640 px, content
  height, scrolling inside the screen) fits desktop and 667x375. `QuestsClientViews.spec` pins "no `size`" in place of
  the old check for `UDim2.fromScale(0.85, 0)`.
- **Claim toast:** a chain or one-time quest that is claimed leaves the board (the ledger holds it), so
  `State.transitions` never saw it turn `claimed` and no "Reward claimed" toast (nor `onClaimed`) fired.
  `Quests.vanishedClaims` (client/init.luau) adds those: a complete quest gone from the snapshot, with no waiting entry
  of the same id (a reset or ended window is not a claim). `State.luau` is untouched. Specs: `QuestsClientApi.spec`.
- **Objective line / chip:** the name and value labels had no layout order (`0/1Visit the tower`); they have 1 and 2
  now. `Row.label` takes `wrapped = false`; the auto-sized reward chip uses it, so it grows to its text instead of
  wrapping (`sta/r`).
- **Goals pill:** the width cap was 60% of `ViewportSize.X` read once at render, and the camera reads ~0 at join, so
  the pill collapsed to "Co…". `Pill.maxWidth(viewportX)` is 60% of the viewport with a floor of `Pill.MIN_WIDTH`
  (160 px); the component follows `ViewportSize` changes and has a `MinSize` of the floor. It stays inactive and
  not selectable.
- **Goal positions:** `Resolve.toVec` reads `{ x, y, z }` (array) and `{ x =, y =, z = }` (named), for the target's
  `position` and for the goal's `fallback`. A malformed position resolves to nothing.
- **667x375:** `tests/QuestsUiFit.spec.luau` runs the `tools/lune/uifit` Checker over the kit's client sources at the four
  standard viewports (desktop, 667x375, 926x428, 1024x768) and pins the board modal, objective, chip, pill and tracker
  rules above. The toasts are `UI.ToastHost` (checked with packages/ui). Real-engine geometry stays a Studio check.
- **ContentId `rbxassetid://203785492` ("Asset type does not match requested type", x6 at join):** `git grep` finds
  it nowhere in the repo (kit, packages/ui, demo), so it is an engine / Studio default asset (Studio's default
  sounds or a Studio-side asset), not something this kit sets. Known-issues text: "At join Studio logs
  `ContentId: rbxassetid://203785492 failed due to: Asset type does not match requested type` six times; the id is not
  set by StudWork or the quests kit and is harmless."

### wire
- **Done (supersedes the docs2 items 1 and 3):** `Goals/server` `wireTarget` sends
  `Validate.toArray(t.position)` (named positions reach the wire as arrays; also for `setNext` answers
  through `wireTarget`); Goals `start` logs `ctx.log.warn("[Goals] <warning>")` for each
  `Validate.warnings(chain, ctx.gameConfig.analytics.funnel)`. Specs: `tests/GoalsWire.spec.luau` (3 of 4
  fail without the change) and the Boot.spec assertion. The framework file touched is listed at the top.
- **Not a server wire item:** `def.fallback` is read by the client from its config, not sent by the server;
  the client `Resolve.vec` fix (docs2 item 2) stays with the client builder.
- **Page text applied** (perf2's Replication / signals / Goals replacements) and checked against
  `Quests/server/init.luau` (`progIds`, `prog`, `Progressed(player, questIds)`) and `Goals/server/init.luau`
  (`onProgressed`, `wantOf`). The "Framework change needed for the funnel warning" bullet in docs2 is now done.

### fix3

- Goals: after the flag goes off and on, the "what's next" provider runs again (the off branch of `onTick` clears `nextAt` for the dropped wheel slot). A Goals objective check on a `leaderboardRank` objective is now `1 <= rank <= target`.
- Quests client: the "Resets in" line shows days from 24 h on (`Quests.resetsInDays` = "Resets in {days}d {hours}h", a new string key in `Quests/module.luau`; add it to the strings list in the kit page); item reward chips show the catalog name (`GameConfig.items` is a list of defs, the old lookup read it as a map); the Odds screen item ids come from `def.id`.
- Not changed, by design: the claim toast sits at the framework Hud's `UI.ToastHost` position (`packages/framework/client/Hud`, `UDim2.new(0.5, 0, 0, 96)`), so it can overlap an open board; "Quick coins" in the Story tab is a repeatable (cap 3, 4 touches per claim) that starts its next cycle at 0/4 after a claim (the chain tab is the "Story" tab for every non-daily/weekly/event kind); the Quests button dot is already derived from the live state (`State.claimable`, which includes waiting rewards from a reset), and the later final-06 shot shows it gone.

### docs3
Kit page (`docs/framework/kits/quests.md`), from the second dogfood and the final review:
- Quick start: quest and goal tables written as StyLua formats them; calls shown through
  `ctx.deps[Quests]` in a game module's `init`/`start` (and `StudWork.use` / `server:use`); "run
  `tools/format`"; step 3 `Boot.spec` `EXPECTED` order spelled out (after the kit modules, before the
  game module, copy the printed order).
- Funnel steps: warning that a step the scaffold already logs (`FirstCollect`) is deduped by the framework
  but counted twice by `server.calls`; use new step names or count distinct.
- Testing your first session: how a spec drives the dailies it was dealt (`Quests.active`).
- Goals config: what to point the arrow at for UI-driven goals (`widget`, `target` optional).
- Review L3: an ack plus an already-met threshold completes on the ack (one sentence in the validation list).
- Known issues O22 (L2), O23 (L5), O24 (Studio warnings) added to section 3; the outside-edits list at the top
  names `getting-started.md` and the `Missions` rename (L4).

### polish

Kit page (`docs/framework/kits/quests.md`) and specs only; all **fixed, not re-dogfooded** (the third dogfood's stuck points):
- Add to an existing game, step 1: says a default-list project already lists Items, Rarity, Inventory, Economy, Upgrades, Rebirth, Offline, Streak, Leaderboards, Badges, Notifications, Friends, Mail, TextFilter and Plot (`tools/lune/KitModules.luau` `ORDER`, the new-game template) so only `Quests` and `Goals` are added; a `--modules` subset must add what its config needs. Fixed, not re-dogfooded.
- Quick start (Goals snippet) and step 4: point to "Typing a goal chain in a strict file" where a mixed chain is shown. Fixed, not re-dogfooded.
- Config: a three-step `chains` example next to the schema (mirrored by `tests/QuestsDocChains.spec.luau`, passes). Fixed, not re-dogfooded.
- Testing your first session: the snippet was run as printed against `examples/quests-demo` (scratch copy, not committed): `Goals.current` needs no `world:advance` after `isLoaded`; the only failures were the demo's own ids (the counter key that completes `story1`), now said in a comment. Fixed, not re-dogfooded.
- Goals config: "Check every widget id" (a typo shows only in Studio). Fixed, not re-dogfooded.
- Strings list: `Quests.resetsInDays` added; the "Resets in h:mm" description mentions days. Review L-b. Fixed, not re-dogfooded.
- Odds screen `def.id` fix: spec `tests/QuestsOdds.spec.luau` runs the real `openOdds` against a fake UI and fails with `local id = key` (review L-a). The O24/O25 order and the ack sentence of the validation list (L-c) are fixed.
- Not reproduced: "tools/format needed two passes on Balance.luau" (see the polish report): one `tools/format` pass left `tools/lint` clean on a mangled copy of the dogfood `Balance.luau` and a second pass changed nothing.
