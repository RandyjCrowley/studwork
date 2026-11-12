# Getting started

From nothing to a game that boots, then your first module. Every command runs from the repo root.

The quickest start is `tools/new-project <path>`: it creates a **single-game project** (one repo
per game, StudWork at `studwork/`) with everything below already done, and every tool there works
without a game name ([single-game-project.md](single-game-project.md)). The steps below are for a
**games repo** (several games in one repo, [games-repo.md](games-repo.md)): run them from its root,
that is where real games live. You can also try it inside a StudWork clone to experiment: `games/` there is git-ignored
scratch space (see "Removing a scratch game" at the end), never committed to the framework.
Moving an existing game instead? See [adopting.md](adopting.md) and the agent playbook
[adopt-existing-game.md](../agents/adopt-existing-game.md).
The checks (`tools/lint`, `tools/typecheck`, `tools/test`) run without Studio. `tools/test` and `tools/lint`
need no network. The **first** `tools/typecheck` in a clone downloads the Roblox type definitions
(one request to `raw.githubusercontent.com`, about 1 MB) into the project's own git-ignored `.cache/`;
`tools/new-project` copies them from the StudWork checkout that made the project, and
`tools/typecheck --offline` never downloads (it fails with a message when they are missing).

## 0. Once per machine

```
tools/install      # the pinned toolchain (Rojo, Lune, Selene, StyLua, luau-lsp, Blink) + Wally packages + git hook
tools/doctor       # every line should say ok
```

## 1. Generate the game

Pick a name: lowercase letters, digits and dashes, 2-32 characters, starting with a letter. Pick
the kit modules the game uses (names below; leave the flag out for all fifteen):

```
tools/new-game my-game --modules Items,Rarity,Inventory,Economy
```

It prints `created games/my-game (servePort N)`. Missing hard dependencies are added and reported
(`--modules Plot` adds Items and Inventory). `--modules ""` gives a foundation-only game (no kits).

The game's own module (`modules/my-game/module.luau`) gets the kits you name in `--modules` that it
uses in `dependsOn` (since v1.7.1; a kit only added as another kit's dependency stays where the
template has it). Without `--modules` it gets the core kits in `dependsOn` and `Leaderboards`, `Badges`,
`Notifications` and `TextFilter` in `optional`. All of them are in `GameConfig.modules`, so
`ctx.deps[Kit]` works for each. The difference: a `dependsOn` kit that is missing from
`GameConfig.modules` fails the boot and its `init` runs before yours; an `optional` kit is no
ordering edge (call it from `start` or later) and `ctx.deps[Kit]` errors while it is off (guard with
`ctx.isEnabled(Kit)` if the game may drop it). Move a kit up to `dependsOn` when the game can't run
without it.

| Kit | Modules | Hard dependencies |
|---|---|---|
| Collection | `Items`, `Rarity`, `Inventory` | Rarity and Inventory need Items |
| Economy | `Economy`, `Upgrades`, `Rebirth`, `Offline` | Upgrades and Rebirth need Economy |
| Base | `Plot` | needs Inventory |
| Social | `Friends`, `Mail`, `TextFilter` | none |
| Engagement | `Streak`, `Leaderboards`, `Badges`, `Notifications` | none (Badges triggers and Leaderboards sources use Streak, Rebirth, Inventory and Economy only when listed) |

What you get in `games/my-game/`:

| Path | What |
|---|---|
| `src/shared/Config/init.luau` | the GameConfig: `gameId`, `modules`, `config`, `items`, `products`, `events`, `client`, `analytics` |
| `src/shared/Config/Balance.luau` | each listed module's config (`config.<Module>`) |
| `src/shared/Config/Items.luau` | items; the `economy = { incomePerSec }` field only when Economy is listed |
| `modules/my-game/` | the game's own module (`module.luau` + `server/init.luau`): your gameplay code |
| `src/server/Main.server.luau` | builds the world and calls `StudWork.start(Config, ServerConfig)` |
| `src/client/Main.client.luau` | `StudWork.start(Config)`, the HUD, an action bar for the listed modules |
| `src/server/Boot.spec.luau` | boots the real Config in the multi-server sim and pins the module list |
| `deploy.json` | placeholder experience ids (0); `tools/publish` refuses them until you fill them in. After pasting real ids, run `tools/sync-projects`: it writes `src/shared/Config/Environments.luau` (`GameConfig.environments`, which makes the test and live places tell themselves apart) from them |

Only the listed modules' code and config are written, so nothing needs trimming by hand. It also
adds a row to `GAMES.md` (when the project has one) and creates `docs/games/my-game.md` (pass
`--no-design-doc` to skip the design doc).

## 2. Check it

```
tools/lint
tools/typecheck my-game
tools/test games/my-game
```

Expected endings: `lint: clean`, `typecheck: clean`, and `3 spec files, 6 tests passed, 0 failed`
(the Config spec, the boot spec and the game-module spec). `tools/lint` also fails on formatting:
`tools/format` fixes it (`tools/format --check` only checks).

## 3. Run it in Studio

```
tools/dev my-game
```

This serves the game with Rojo on its port and prints the Studio steps: open a Baseplate, connect
with the Rojo plugin, press Play. With the template loop you touch the glowing block to collect an
item; with Economy listed the coins counter rises.

## 4. Change a default (level 2)

Edit `src/shared/Config/Balance.luau`, for example `Economy = { ..., income = { tickSeconds = 5,
source = "owned" } }`. `StudWork.start` validates every module's config at boot and reports all
problems at once. See [the five override levels](override-levels.md).

## 5. Your first module (level 5)

```
tools/make-module Quests --game my-game
```

It writes `games/my-game/modules/quests/` (definition, server part, client part, a harness test,
README) and maps it in `games/my-game/default.project.json`. Then:

1. In `src/shared/Config/init.luau`, under `local ReplicatedStorage = ...`, add
   `local GameModules = ReplicatedStorage:WaitForChild("Modules")`, and add this line to `modules`:
   `require(GameModules:WaitForChild("Quests"):WaitForChild("module")),`
2. In `src/server/Boot.spec.luau`, add `"Quests",` to `EXPECTED` just before the game's own module
   (the last entry).
3. Run:

   ```
   tools/test games/my-game/modules/quests
   tools/test games/my-game/src/server
   tools/typecheck my-game
   tools/lint
   ```

   Expected: the module's own spec (2 tests) and the boot spec pass; typecheck and lint are clean.

Your module's spec uses `StudWork.test.harness` (`tools/make-module` writes one). How a spec drives the
game module against the kits (options, `h:console`, `h:action`, `h:sent`, the fake Workspace) is in
[testing.md](testing.md). The console commands your module registers are typed with its
**lower-case name** in front: module `Quests` -> `quests reset`.

Next: [concepts](concepts.md), the [module API reference](module-reference.md), the
[generators](generators.md), and the [example module](../../examples/modules/session-leaderboard/README.md).

## Removing a scratch game

`tools/new-game` touches up to three places: `games/<name>/`, `docs/games/<name>.md` and a row in
`GAMES.md` (if the project has one). Delete them.
