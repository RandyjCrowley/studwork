# SessionLeaderboard (example third-party module)

A live top-N of the points players earn **this session**, plus each player's best session ever.
It is written the way any third-party module would be: it imports only the public StudWork API
(`StudWork.defineModule`, `StudWork.hook`, `StudWork.use`) and uses only what `ctx` gives it. No
framework internals, no kit internals. It is the module-api.md §18 sketch, made real.

What it shows:

| Feature | Where |
|---|---|
| Its own config with defaults | `module.luau` `config` (`GameConfig.config.SessionLeaderboard`) |
| Its own save section, replicated to its owner | `data` key `sessionLeaderboard`: `best` replicates, `sessions` stays on the server |
| An optional dependency and its signal | `optional = { Economy }`; `ctx.deps[Economy].signals.CurrencyChanged` only when `ctx.isEnabled(Economy)` |
| The shared ticker | `ctx.lifecycle.onTick(config.tickSeconds, ...)` |
| Replicated state | `ctx.replicate.setAll("top", ...)` for everyone, `ctx.replicate.set(player, "earned", ...)` for the owner |
| An extension point for others | `api.onNewBest(fn)` built on `StudWork.hook()` |
| A theme token | `theme.colors.leaderboardHighlight` |
| A HUD widget and a screen | `client/Widget.luau` (slot `right`), `client/Screen.luau` (`"Leaderboard"`) |
| Tests without Studio | `tests/` (framework harness + the real kit modules in the sim) |

## Add it to a game

1. Map it in the game's `default.project.json` (paths relative to the project file; this is
   `games/<game>/` in the core repo; in a games repo the module lives under `../../roblox-core/`).
   Once a project maps it, `tools/sync-projects` keeps its entries canonical (v1.4.0); adding just
   `"SessionLeaderboard": { "$className": "Folder" }` under `ReplicatedStorage.Modules` and running
   `tools/sync-projects` writes the rest. `examples/overrides/ov-f` is a working example:

   ```json
   "ReplicatedStorage": {
     "Modules": {
       "$className": "Folder",
       "SessionLeaderboard": {
         "$className": "Folder",
         "module": { "$path": "../../examples/modules/session-leaderboard/module.luau" },
         "client": { "$path": "../../examples/modules/session-leaderboard/client" }
       }
     }
   },
   "ServerScriptService": {
     "Modules": {
       "SessionLeaderboard": { "$path": "../../examples/modules/session-leaderboard/server" }
     }
   }
   ```

   (`ServerScriptService.Modules` already exists in a generated game: add the entry to it.)

2. List it in `GameConfig.modules` (`src/shared/Config/init.luau`):

   ```lua
   local GameModules = ReplicatedStorage:WaitForChild("Modules")
   -- ...
   modules = {
   	-- the kit modules ...
   	require(GameModules:WaitForChild("SessionLeaderboard"):WaitForChild("module")),
   },
   ```

3. Optional: set its config in `Balance.luau`, `SessionLeaderboard = { top = 5 }`.

With Economy in the game, every positive `CurrencyChanged` counts. Without it, report points from
your game module: `ctx.deps[SessionLeaderboard].add(player, 1)` (declare it in your game module's
`dependsOn`).

## Config (`GameConfig.config.SessionLeaderboard`)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `top` | integer 1..50 | `10` | rows in the shared top list |
| `tickSeconds` | number >= 1 | `5` | how often the top list is rebuilt and bests are saved |
| `currency` | string? | `nil` | count only this currency's gains (`nil` = every currency) |

## Server API (`StudWork.use(SessionLeaderboard)`, `ctx.deps[SessionLeaderboard]`)

| Function | Returns |
|---|---|
| `earned(player)` | points this session (0 when not loaded) |
| `best(player)` | the best session ever, as saved (saved every `tickSeconds` and on leave) |
| `sessions(player)` | sessions started in this game |
| `top()` | the top list as of the last tick: frozen `{ { userId, name, earned } }` |
| `add(player, amount)` | adds points; errors unless `amount` is a finite number > 0; `false` when the player isn't loaded |
| `onNewBest(fn(player, best))` | runs `fn` after a new best session is saved |

## Client API (`StudWork.use(SessionLeaderboard)` on the client)

| Member | Returns |
|---|---|
| `state()` | this module's replicated slice: `{ data = { best }, extra = { top, earned } }` |
| `summary()` | `{ earned, best, rows = { { rank, name, earned, isYou } }, yourRank }` for the local player |
| `open()` | opens the `"Leaderboard"` screen |

The widget registers as `"SessionLeaderboard.top"` in the HUD's `right` slot; hide it with
`client.hud.widgets = { ["SessionLeaderboard.top"] = false }`. Replace the screen by registering
your own `"Leaderboard"` screen (`tools/make-screen <game> Leaderboard`).

## Save data (section `sessionLeaderboard`, version 1)

```lua
{ best = 0, sessions = 0 } -- replicated to the owner: best
```

## Tests

```
tools/test examples/modules/session-leaderboard
```

- `tests/SessionLeaderboard.spec.luau`: the framework harness, with and without Economy (the real
  Economy definition with a stand-in server part that fires `CurrencyChanged`): points, config,
  ticker, replication, the saved best, config validation.
- `tests/View.spec.luau`: the client view-model.
- `tests/RealKits.spec.luau`: boots `tests/fixture-game` (Items, Inventory, Economy and this
  module) through `StudWork.start` in the multi-server sim with the real kit modules; real income
  becomes points and a saved best. It needs `examples` in the sim's source roots
  (`packages/framework/test/sim/Loader.luau`).
