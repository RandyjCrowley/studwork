# Getting started

From nothing to a game that boots, then your first module. Every command runs from the repo root.
The checks (`tools/lint`, `tools/typecheck`, `tools/test`) run offline in Lune, without Studio.

## 0. Once per machine

```
tools/install      # the pinned toolchain (Rojo, Lune, Selene, StyLua, luau-lsp, Blink) + Wally packages + git hook
tools/doctor       # every line should say ok
```

## 1. Generate the game

Pick a name: lowercase letters, digits and dashes, 2-32 characters, starting with a letter. Pick
the kit modules the game uses (names below; leave the flag out for all eleven):

```
tools/new-game my-game --modules Items,Rarity,Inventory,Economy
```

It prints `created games/my-game (servePort N)`. Missing hard dependencies are added and reported
(`--modules Plot` adds Items and Inventory). `--modules ""` gives a foundation-only game (no kits).

| Kit | Modules | Hard dependencies |
|---|---|---|
| Collection | `Items`, `Rarity`, `Inventory` | Rarity and Inventory need Items |
| Economy | `Economy`, `Upgrades`, `Rebirth`, `Offline` | Upgrades and Rebirth need Economy |
| Base | `Plot` | needs Inventory |
| Social | `Friends`, `Mail` | none |
| Engagement | `Streak` | none |

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
| `deploy.json` | placeholder experience ids (0); `tools/publish` refuses them until you fill them in |

Only the listed modules' code and config are written, so nothing needs trimming by hand. It also
adds a row to `GAMES.md` and creates `docs/games/my-game.md` (pass `--no-design-doc` to skip the
design doc).

## 2. Check it

```
tools/lint
tools/typecheck my-game
tools/test games/my-game
```

Expected endings: `lint: clean`, `typecheck: clean`, and `2 spec files, 2 tests passed, 0 failed`
(the Config spec and the boot spec).

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

Known gap: `games/my-game/src/shared/Config.spec.luau` can't load a Config that lists a module
from `ReplicatedStorage.Modules` yet (the Lune test runner's fake `ReplicatedStorage` only knows the
framework and kit folders; requested from the framework owner), so `tools/test games/my-game`
reports that one spec until it's fixed. The boot spec covers the same validation with the real
project mapping.

Next: [concepts](concepts.md), the [module API reference](module-reference.md), the
[generators](generators.md), and the [example module](../../examples/modules/session-leaderboard/README.md).

## Removing a scratch game

`tools/new-game` touches three places: `games/<name>/`, `docs/games/<name>.md` and a row in
`GAMES.md`. Delete all three.
