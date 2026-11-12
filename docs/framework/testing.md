# Testing a game

Specs run in Lune, without Studio and without Roblox: `tools/test [paths]` runs every `*.spec.luau`
under `src/` and `modules/` (a single-game project) or the game folder (games repo), with
`describe`, `it` and `expect` as globals. `StudWork.test` boots the **real** framework and the **real**
kit modules against in-memory stand-ins for the engine, so a spec drives your module the way a
player would. Nothing here calls Roblox services or Open Cloud.

The scaffold already has the shape: `src/server/GameModule.spec.luau` (the game module against the
kits), `src/server/Boot.spec.luau` (the whole game in the multi-server sim) and
`src/shared/Config.spec.luau`. Copy `GameModule.spec.luau` for your own gameplay specs.

## A spec for the game's own module

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local GameModule = require(ReplicatedStorage:WaitForChild("GameModule"):WaitForChild("module"))
local ServerConfig = require(script.Parent.ServerConfig)

local function boot(extra)
	local modules = table.clone(Config.modules)
	table.insert(modules, GameModule) -- the framework adds the game's module at boot; a spec lists it
	local options = {
		gameId = Config.gameId, modules = modules, config = Config.config,
		items = Config.items, products = Config.products, events = Config.events,
		serverConfig = ServerConfig, isStudio = true,
	}
	for key, value in extra or {} do options[key] = value end
	return StudWork.test.harness(options)
end

it("scores a point", function()
	local h = boot({ flags = { pointsBoard = { default = true } } })
	local p = h:addPlayer({ userId = 1 })
	-- a console command, typed with the module's lower-case name; the reply is the handler's return
	expect(h:console("mygame", "points")).toBe("points=1")
	expect(h:saved(p)).never.toBeNil()
end)
```

How the pieces are found:

- **Kit modules** run for real. A module's server part is looked up the way a live game does
  (`ServerScriptService.Modules.<Name>` from `default.project.json`), so the kits **and your game
  module** need no `servers` table. `servers = { Name = part }` injects a part instead (a test
  double, a stub, or a part you built by hand); it wins over the lookup.
- **`Plot` and anything else that builds instances** needs a world Lune doesn't have: leave it out of
  a spec's module list (the scaffold's spec does) and let `Boot.spec` boot it in the sim.
- `StudWork.test.boot(opts)` is `harness` that returns `(h?, err?)` instead of raising: for a spec
  that expects a boot error (a bad config must fail closed).

### Harness options

`modules` (required) and the `GameConfig` fields: `gameId`, `config` (`config.<Module>` tables),
`items`, `products`, `events`, `theme`, `compliance`, `analytics`, `flags`, `flagOverride`,
`environments`, `strings`, `localization`, `storeBudgets`; plus `serverConfig` (the second argument
of `StudWork.start`: admins, hidden flags, `openCloud.secrets`) and these test-only options:

| Option | What |
|---|---|
| `servers = { Name = part }` | inject a module's server part (wins over the project lookup) |
| `services = { Name = fake }` | `ctx.services.get("Name")` fakes: `StudWork.test.fakes.badgeService()`, `textService()`, `userService()`, `configService()`, `translator()`, `experienceNotificationService()` (module-api §23.6, §23.10) |
| `openCloud = StudWork.test.fakes.openCloud()` | the `ctx.openCloud` transport; its `requests` list records every call |
| `secrets = { [name] = true }` | secrets-store names that "exist" |
| `env = "studio" \| "test" \| "live"`, `placeId`, `universeId`, `isStudio` | the environment the server believes it is in |
| `flags`, `flagOverride` | GameConfig flags (above) and the live override |
| `locale`, `translator` | the players' locale and translator fake |
| `census = { servers, players, peakPlayers? }` | a fixed census reading |
| `startTime` | the fake clock's start (default `1_700_000_000`) |
| `store = StudWork.test.memoryStore()` | share one save store between harnesses (several servers); `store.failNext(n)` makes the next n loads/saves raise |
| `legacy = StudWork.test.legacyStore(seed)` | an adopted game's old stores, read-only |
| `policy`, `owned` | `PolicyService` answers per user id; gamepass ownership per user id |

### Harness methods

| Call | What |
|---|---|
| `h:addPlayer({ userId, name?, data?, sync? })` | a mock player joins: seeded save (`data`), data loads, state is sent; returns the player (`p.loaded`, `p.UserId`, `p.Name`, `p.kicked`) |
| `h:removePlayer(p)` | leaves (saves and releases) |
| `h:rejoin(p, { secondsAway })` | save, leave, advance the clock, load again (migrations, offline payouts) |
| `h:tick(seconds)` | advance the clock and run every timer and the shared ticker, one second at a time |
| `h.clock` | the fake clock (seconds); add to it to jump time without ticking |
| `h:use(Ref)` | a module's frozen public API (what `StudWork.use` returns) |
| `h:action(p, Ref, "name", ...)` | **the client calling a module's action** (below) -> `(ok, result \| reason)` |
| `h:console(...)` | one console line, e.g. `h:console("economy", "grant", "100", "Coins", "1")` -> the reply text |
| `h:sent(Module?, Event?)` | what the server sent to clients through a module's own Blink events (below) |
| `h:fire(p, "StateInit")`, `h:state(p)` | a framework Blink client event; the replicated state that player was last sent |
| `h:purchase(p, "Product", { retries?, redeliver?, price?, purchaseId? })`, `h:receipt({...})` | a developer-product purchase through `ProcessReceipt` |
| `h:saved(p)` | the stored save (sectioned) |
| `h:orderedStore(Module, name)`, `h:sortedMap(Module, name)` | the in-memory store behind a module's ordered store or sorted map |
| `h:warnings()`, `h.logs` | `warn` lines / every `{ level, msg }` the framework logged |
| `h.fake` | recorded engine traffic: `fake.analytics`, `fake.serverEvents`, `fake.kicks`, `fake.synced` |
| `h:shutdown()` | server shutdown (saves everyone) |

`h.players` maps user id to the mock player.

### The client's side: actions and what the server sends

There is no Blink wire under Lune. Instead:

- **The client asks the server** (a module's `actions`, module-api §9): `h:action(p, Ref, "name",
  ...)`. It takes the same path as a wire call (left player, not loaded, rate limit, `pcall`) and
  returns `(ok, result)`. Example: the Notifications opt-in answer is
  `h:action(p, Notifications, "optInShown", requestId, true)`.
- **The server asks the client** (`ctx.net.fire(player, part.net.PromptOptIn, ...)`): a module with a
  `net.blink` gets a fake `part.net` with one recording event per event in that file, so calls such
  as `Notifications.suggestOptIn(p, "key")` return `true` here. Read what was sent with
  `h:sent("Notifications")`, `h:sent("Notifications", "PromptOptIn")` -> `{ { event = "Notifications.PromptOptIn", player = p, args = { requestId } } }`.
  A part you inject yourself in `servers` keeps its own `net`.

### The fake world

Game code often reads engine services at the top of a file or in `start`. In a spec:

- `game:GetService("Workspace")` / `workspace`: an **empty** world. `FindFirstChild*` return `nil`,
  `GetChildren`/`GetDescendants` return `{}`; any other member errors. A module that hooks a part
  (`Workspace.World.Block.Touched`) should look it up with `FindFirstChild`, treat `nil` as "not
  built" (the scaffold logs one warning and goes on), and keep the hookup in its own function so a
  spec can call it with a fake part.
- `game:GetService("Players")`: `GetPlayers()` / `GetPlayerByUserId()` return the players the harness
  added (`h:addPlayer`); `PlayerAdded:Connect` accepts a function and never fires (use
  `ctx.lifecycle.onPlayerLoaded`).
- `game:GetService("HttpService")`: `GenerateGUID`, `JSONEncode`, `JSONDecode`; no requests.
- Any other service errors with "not available in Lune tests; inject it": get it through
  `ctx.services.get("Name")` and pass a fake in `services` (module-api §23.6).

### Console commands

A module registers `ctx.console.register("points", fn, help)`; the command is typed with the module's
**lower-case name** in front: module `DogfoodGame` -> `dogfoodgame points`; module `Economy` ->
`economy grant`. In a spec: `h:console("dogfoodgame", "points")`; in Studio's command bar:
`game.ServerScriptService.Framework.StudWorkConsole:Invoke("dogfoodgame", "points")`. `Invoke("help")`
lists every command with its prefix. The handler is `fn(player, ...)`; name the first parameter
`_player` when you don't use it (selene's `unused_variable` ignores a leading underscore). Registering
in `init` is the rule; guard Studio-only commands with `if ctx.isStudio then` (a spec sets
`isStudio = true`).

## The kits' own specs

The kit pages (`docs/framework/kits/`) show a spec per module. Those specs live inside this
repository and use internal paths (`packages/framework/test/harness.luau`) that a game can't reach;
a game uses `StudWork.test.*` only: `harness`, `boot`, `memoryStore`, `legacyStore`, `player`,
`fakes.*` and `sim.*`.

## The multi-server sim

`StudWork.test.sim` runs the real ProfileStore on a mock DataStore with several servers, crashes,
latency and failure injection. `Boot.spec.luau` uses `F.bootGame("default.project.json")` to boot the
whole game in it. See `packages/framework/test/sim/README.md` in the framework.

## Before you commit

```sh
tools/format      # stylua over your files (tools/lint fails when it would change anything)
tools/lint
tools/typecheck
tools/test
```
