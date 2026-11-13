# quests-demo: the quests kit's fixture game

The fixture game of the quests kit ([Quests and Goals](../../docs/framework/kits/quests.md)): every
quest kind, every goal check form and every piece of the kit's UI, in a small world built in code.
It is the Studio place for the kit's checks and the visible demo. Never published (deploy.json ids
are placeholders).

- Modules: Items, Rarity, Inventory, Economy, Quests, Goals, and the game's own module `QuestsDemo`
  (`modules/quests-demo/`, console prefix `questsdemo`).
- Dev: `tools/dev quests-demo` (rojo serve on port **34960**).
- Specs: `src/server/Boot.spec.luau` (boots the real project in the sim, no errors, no warnings),
  `src/server/Console.spec.luau` (the Studio-only commands), `src/shared/Config.spec.luau` (valid
  config, funnel steps, string keys), `src/server/FirstMinutes.spec.luau` (a new player's first
  three minutes; added by the Goals builder).

## The world (built by the game module from `src/shared/Config/Tuning.luau`)

Under `Workspace.DemoWorld`:

| Part | What it does |
|---|---|
| 6 coin spots, tagged `DemoCoin` | a touch grants 5 Coins and `Quests.progress(player, "coinTouched")` |
| `DemoGuide` | `Quests.progress(player, "guideVisited")` and `Quests.grant(player, "guideGift")` |
| `DemoBoard`, tagged `DemoBoard` | `Quests.progress(player, "boardVisited")`; the "what's next" target after the chain |
| `DemoTower`, 600 studs away | `Quests.progress(player, "towerVisited")` and `Goals.complete(player, "reachTower")`; beyond the streaming radius, so the pointer uses the edge arrow and the goal's `fallback` |

Counter keys: `coinTouched`, `guideVisited`, `boardVisited`, `towerVisited`.

## Config (`src/shared/Config/Balance.luau`)

- **Quests:** a daily pool of 6 (`dailyEarn` is a `currencyEarned` source, `dailyCrate` rewards a
  roll of the free table `DemoCrate`, `dailyRich` is a `currency` threshold), `count = 3`,
  `rerollsPerSlot = 1`; weekly 2 of 3; the story chain `story` = `story1`..`story3`; the repeatable
  `repeatCoins` (cap 3 a day); the one-time `guideGift` (`offer = "grant"`, handed out by the
  guide); the event quest `eventCoins` on `GameConfig.events.demoEvent` (no schedule, 600 s).
- **Goals:** `firstCoins` (currency >= 10, target tag `DemoCoin`, funnel `FirstCoins`), `openBoard`
  (ack; widget `Quests.button`; the demo client sends `ackGoal` when the player opens the board
  while it is the current goal; funnel `OpenedBoard`), `firstClaim` (`story1` claimed, target path
  `Workspace.DemoWorld.DemoGuide`, funnel `FirstClaim`), `reachTower` (a game call, target position
  of the tower with `fallback`, funnel `ReachedTower`). After the chain, `Goals.setNext` points at
  the board with `game.next.dailies`.
- `analytics.funnel = { "Joined", "FirstCoins", "OpenedBoard", "FirstClaim", "ReachedTower" }`;
  every `game.*` key (quest titles, objective labels, goal texts, `game.next.dailies`) is in
  `GameConfig.strings`, so Studio logs no missing-key warning.

## Copying this into your game

The demo's `Balance.luau` shows a mixed goal chain typed as a plain list (`{ any }`); a game with a
strict `Balance.luau` can type it `Types.Chain` instead ([typing a goal chain](../../docs/framework/kits/quests.md#typing-a-goal-chain-in-a-strict-file)).
To add the kit to a game that already exists, follow
[Add Quests and Goals to an existing game](../../docs/framework/kits/quests.md#add-quests-and-goals-to-an-existing-game).
The demo has no `nextGoal` pill (its client doesn't pass one). Its `reachTower` goal's position is
the array form; `{ x = , y = , z = }` is accepted too.

## Fixture-only overrides

These make the demo quick to watch. **Never copy them into a real game:**

| Setting | Demo | Default | Why |
|---|---|---|---|
| `config.Quests.foldSeconds` | `5` | `30` | pending progress joins the save within seconds |
| `config.Quests.replicateSeconds` | `0.5` | `1` | live progress reaches the board and tracker faster |
| `Workspace.StreamingTargetRadius` (default.project.json) | `256` | `1024` | the tower (600 studs) streams out, so the edge arrow and `fallback` are visible |

## Studio-only console commands

From the Studio command bar (Server context, during Play):
`game.ServerScriptService.Framework.StudWorkConsole:Invoke("questsdemo progress coinTouched 5")`.
Each is refused outside Studio (`ctx.isStudio`); the console is server-only, no client can call it.

| Command | Does |
|---|---|
| `questsdemo progress <key> <n> [userId]` | `Quests.progress(player, key, n)` |
| `questsdemo finishchain [userId]` | `Goals.complete` for every goal of the chain |
| `questsdemo event` | starts `demoEvent` now (the event quest's window) |
| `questsdemo grant [userId]` | `Quests.grant(player, "guideGift")` |
| `quests complete <questId> [userId]` | the kit: fills every objective of a quest |
| `quests timeshift <seconds>` | the kit: shifts this server's quest clock (a daily reset in seconds) |
| `goals complete <goalId> [userId]` | the kit: marks a goal done |
| `goals reset [userId]` | the kit: starts the chain over |

`[userId]` defaults to the first loaded player.

## Studio checks and where to see them

| Check | Surface |
|---|---|
| Board: Daily / Weekly / Story tabs | the HUD button `Quests.button` opens the `Quests` screen |
| Live progress | touch coin spots: `dailyCrate`, `story2`, `repeatCoins` move |
| Claim and toast | finish `story1` at the guide, claim it on the board |
| Reroll | a daily slot's Reroll (1 free a day) |
| Tracker | pin a quest: the `Quests.tracker` widget |
| Roll reward Odds button | `dailyCrate`, `weeklyTouches` and `story3` reward a `DemoCrate` roll |
| Event tab | `questsdemo event` |
| Pill and beam to `DemoCoin` | the first goal, at join |
| Edge arrow to the tower | the fourth goal (the tower is streamed out at 256 studs) |
| Chain end -> "what's next" | `questsdemo finishchain`: the pill shows `game.next.dailies`, the beam points at the board |
| `topCenter` at 667x375 | Device Emulator: the Goals pill and the currency widget don't overlap |

To write the same for your own game: the kit page's [Testing your first session](../../docs/framework/kits/quests.md#testing-your-first-session)
(drive the dailies a player was dealt via `Quests.active`, use funnel step names the scaffold doesn't log).
