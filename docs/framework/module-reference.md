# Module API reference

The public API every module uses, built-in kits and third-party modules alike. Derived from the
design ([module-api.md](module-api.md)) and the code in
`packages/framework`. Where they differ, this page follows the code and says so.

Public surface: `StudWork` (`ReplicatedStorage.Framework`) and the `ctx` your module receives.
Everything under `packages/framework/server` and `packages/framework/client`
is internal: modules and games never require it.

- [StudWork](#studwork)
- [The definition: defineModule](#the-definition-definemodule)
- [The config schema language](#the-config-schema-language)
- [The server part](#the-server-part)
- [ctx](#ctx)
- [Save data](#save-data)
- [Transactions](#transactions)
- [Extensions and signals](#extensions-and-signals)
- [Purchases](#purchases)
- [Random outcomes: Compliance](#random-outcomes-compliance)
- [Networking and actions](#networking-and-actions)
- [Replication and client state](#replication-and-client-state)
- [The client part](#the-client-part)
- [Items and item fields](#items-and-item-fields)
- [Rojo layout](#rojo-layout)
- [Testing](#testing)
- [Errors you will see](#errors-you-will-see)

## StudWork

```lua
local StudWork = require(game:GetService("ReplicatedStorage"):WaitForChild("Framework"))
```

| Member | What |
|---|---|
| `StudWork.VERSION` | `"1.3.0"` |
| `StudWork.defineModule(spec) -> ModuleRef` | validates and freezes a definition; no side effects |
| `StudWork.isModuleRef(value) -> boolean` | true only for values returned by `defineModule` |
| `StudWork.start(GameConfig, ServerConfig?)` | boots the side it runs on; call once per side (a second call errors) |
| `StudWork.use(ref) -> API` | the module's frozen API on this side: the server `api`, or on the client `{ actions, state, ...api }`. A module that isn't enabled gives a proxy that errors `"<Name> is not enabled in GameConfig.modules"` on any access. Errors before `StudWork.start`, and after a failed boot with the boot message |
| `StudWork.<Name>` | untyped shortcut for every enabled module (`StudWork.Economy.grant(...)`), for the command bar and console. Typed code uses `StudWork.use` |
| `StudWork.Client` | client only, after `StudWork.start(Config)`: `state` (the whole replicated state) plus the framework UI (`Hud`, `Feedback`, `Input`) |
| `StudWork.hook() -> { register, fire, count }` | a small handler list for offering extensions |
| `StudWork.env` (v1.7.0) | `name() -> "studio" \| "test" \| "live"`, `placeId()`, `universeId()`; both sides, after `StudWork.start` (module-api §23.1, [environments](kits/environments.md)). A facade member, not a module |
| `StudWork.flags` (v1.7.0) | `isOn(name)`, `onChanged(name, fn(on)) -> Connection`, `all()`, `source(name) -> "config" \| "override"`; both sides (§23.2). An undeclared name errors; a `serverOnly` flag errors on the client |
| `StudWork.text(key, args?)` (v1.7.0) | client only: a string in the player's language (§23.9, [localization](kits/localization.md)); the UI kit has `UI.text` and `UI.useText` |

`StudWork.use` accepts only a ModuleRef. `StudWork.use("Data")`, `StudWork.Data`, `.Shop`,
`.Compliance`, `.Net`, `.Replication`, `.Policy` all error: those are framework internals, reached
only through the scoped `ctx` inside a module. `StudWork` is read-only, and any item-registration
style member errors (items exist only through `GameConfig.items`).

## The definition: defineModule

```lua
-- module.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Economy = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))

return StudWork.defineModule({
	name = "Quests",                 -- unique, PascalCase, <= 48 chars; also the config key
	version = "0.1.0",               -- the module's own semver
	framework = "^1.3.0",            -- compatible framework versions, checked at boot
	description = "Daily quests",    -- optional
	dependsOn = {},                  -- hard dependencies (refs); they must be listed in GameConfig.modules
	optional = { Economy },          -- soft dependencies: used only if the game lists them
	config = {
		schema = { dailyCount = "integer(1..10)", rewardCurrency = "string?" },
		defaults = { dailyCount = 3 },
	},
	data = {
		key = "quests",              -- this module's save section
		version = 1,
		default = { done = {}, streak = 0 },
		migrations = script.Parent.migrations, -- a folder of NNN_*.luau, or { [toVersion] = fn }
		replicate = { "done" },      -- fields the owning client sees; false/nil = none
		serverOnly = {},             -- fields that never replicate
		sanitize = nil,              -- fn(section) -> section, once after migrations on load
		adopts = nil,                -- "OldModuleName": take over a disabled module's section
	},
	itemFields = { item = { quests = { questId = "string?" } } },
	theme = { colors = { questGold = "#FFD23F" } },
	server = "Quests",               -- name under ServerScriptService.Modules (default: name)
	client = "Quests",               -- name under ReplicatedStorage.Modules (nil = no client part)
	strings = { ["Quests.title"] = "Daily quests" }, -- (v1.7.0) English defaults; or fn(config) -> table
})
```

Rules (all problems are reported together, naming the module):

- Unknown top-level or `data` fields are errors.
- `dependsOn`/`optional` hold refs, never strings; a module can't be in both.
- `data.key`: `[%w_-.:]`, <= 48 chars, not starting with `_` (framework-reserved). `data.version`
  is an integer >= 1. `data.default` is a plain table. Migration keys are integers between 1 and
  `data.version`.
- `data.replicate = true` is refused: list the fields. Each listed field must exist in
  `data.default`.
- `config.defaults` keys must exist in `config.schema` and match it.
- `itemFields` kinds are `item` and `mutation`; a namespace can't be a base item field.
- `theme` groups: `colors` (`#RRGGBB`), `fonts`, `metrics`, `sounds`, `rarity`, `preset`.
- `strings` (v1.7.0): keys start with `<ModuleName>.`, values are non-empty strings; a function gets the
  merged config and runs once at boot ([localization](kits/localization.md)).

At boot (not at definition time): names and data keys unique among enabled modules, the
`framework` range compatible, hard dependencies listed, no cycles.

## The config schema language

| Form | Meaning |
|---|---|
| `"number"` `"integer"` `"string"` `"boolean"` `"table"` `"function"` `"any"` | a type |
| `"T?"` | optional (nil allowed) |
| `"{T}"` | a list of T |
| `"{[string]: T}"` | a map from string to T |
| `'"multiply"\|"add"'` or `"enum(multiply,add)"` | one of these strings |
| `"number(0..1)"`, `"integer(1..)"`, `"number(..10)"` | a range, inclusive, open ends allowed |
| `{ type = "<type string>", description = "...", default = ... }` | a described key |
| `{ key = <entry>, ... }` | a nested table |

`GameConfig.config.<Name>` is deep-merged over `config.defaults` and checked. Type errors fail the
boot; unknown keys are warnings ("typo?"). `ctx.config` is the merged, frozen result.
`ServerConfig.<Name>` is server-only config (admin ids and the like), never replicated:
`ctx.serverConfig`.

## The server part

`server/init.luau` returns a table; every field is optional:

```lua
return {
	init = function(ctx) end,     -- register handlers, actions, console commands. No yielding,
	                              -- no calls into other modules' APIs (they error during init).
	start = function(ctx) end,    -- connect events, start loops (ctx.lifecycle.onTick),
	                              -- call dependencies. Must not yield either.
	api = { ... },                -- public functions (StudWork.use / ctx.deps); frozen at boot
	txApi = { ... },              -- fn(tx, ...): operations inside a dependent's transaction
	extensions = { ... },         -- hooks dependents register into (callable during init)
	purchaseOps = { ... },        -- fn(tx, ...): operations inside a purchase (tx.use(ref).x)
	actions = { ... },            -- client -> server requests (see Networking)
	net = <generated Blink server module>, -- the module's own events, if it has net.blink
}
```

A module with only a definition (config, data or theme, no code) is valid: no server part needed.

The framework wraps `api`, `txApi`, `extensions` and `purchaseOps` **before** `init` runs, so
those tables must be complete when the server part is required. Keep module state in locals
reset in `init` (a second boot, as in tests, must not see the first one's players).

## ctx

Every field is scoped to the module that receives it.

| Field | What |
|---|---|
| `ctx.name` | the module's name |
| `ctx.config` | merged, validated, frozen config |
| `ctx.gameConfig` | read-only: `gameId`, `items`, `products`, `events` (not other modules' config) |
| `ctx.serverConfig` | this module's part of `ServerConfig` (frozen) |
| `ctx.deps[Ref]` | a declared dependency's `api` (hard or optional). A disabled optional dependency is the erroring proxy, so check `ctx.isEnabled` first. Indexing an undeclared ref errors and names the fix |
| `ctx.depsTx[Ref]` | a declared dependency's `txApi` |
| `ctx.depsExt[Ref]` | a declared dependency's `extensions` |
| `ctx.isEnabled(Ref) -> boolean` | whether the game lists that module |
| `ctx.data` | this module's save section: `get(player)` (frozen view), `update(player, fn(section)) -> boolean`, `isLoaded(player)`, `onLoaded(fn(player))`, `sectionVersion(player)`, `saveAsync(player) -> boolean` (yields until every section is saved), `messages` (below) |
| `ctx.data.messages` | cross-server messages to another user's save, delivered to this module where that user next loads: `send(userId, payload) -> boolean`, `onReceive(fn(player, payload, processed))` (call `processed()` once consumed; at-least-once), `nudge(userId)` |
| `ctx.tx(player, fn(tx)) -> (ok, result)` | one atomic change across modules ([Transactions](#transactions)) |
| `ctx.section(tx)` | this module's own writable section inside a tx |
| `ctx.framework` | read-only facts: `firstJoin(player)`, `lastSeen(player)` (unix seconds), `sessions(player)` |
| `ctx.lifecycle` | `onPlayerLoaded(fn(player))` (after load + migrations, before the first replication), `onPlayerRemoving(fn(player))` (before the final save; no yielding), `onTick(seconds, fn(dt))` (one shared batched ticker for every module), `onShutdown(fn())` |
| `ctx.signals` | `new(name) -> Signal` (named `<Module>.<name>`), and `framework` (framework signals such as `PlayerLoaded`, `PlayerRemoving`) |
| `ctx.net` | `handle(eventName, fn)`, `handleEvent(name, blinkEvent, { rate, burst }, fn)`, `feedback(player, kind, text, rarity?, position?)`, `fire(player, blinkEvent, ...)`, `fireAll(blinkEvent, ...)` |
| `ctx.replicate` | `set(player, key, value)`, `setAll(key, value)`, `sent(player, key)` (the value last handed to the transport) |
| `ctx.compliance` | `registerRandomSource`, `roll`, `spendForRoll`, `tagPaid`, `isPaidCurrency`, `paidCurrencies`, `disclose`, `disclosed`, `registerCurrencySpender` ([Compliance](#random-outcomes-compliance)) |
| `ctx.shop` | `onProduct(product, fn(tx))`, `onPassOwned(pass, fn(player))`, `ownsPass(player, pass)` ([Purchases](#purchases)) |
| `ctx.events` | `schedule(id, schedule?, fn(event))`, `trigger`, `isActive(id)`, `onEnded(id, fn)` (live events from `GameConfig.events`) |
| `ctx.policy` | read-only: `paidRandomRestricted(player)`, `isKnown(player)`, `allows(player, field) -> boolean` (v1.7.0: a boolean `PolicyService` permission field such as `IsContentSharingAllowed`; false until the lookup succeeds), `restricted(player, field) -> boolean` (v1.7.0: `ArePaidRandomItemsRestricted` or `IsSubjectToChinaPolicies`; true until the lookup succeeds) |
| `ctx.analytics` | `funnel(player, step)`, `economy(...)`, `custom(player, name, value, fields?)` |
| `ctx.console` | `register(command, fn(player, ...), help?)`; the command is typed with the module's lower-case name in front: module `MyGame` -> `mygame points` (`Invoke("mygame", "points")`, `h:console("mygame", "points")`). `player` is nil from the Studio command bar and `h:console`: take the target's user id as an argument ([testing.md](testing.md#console-commands)). Name an unused first parameter `_player` (selene's `unused_variable`) |
| `ctx.log` | `info`, `warn`, `debug`, tagged `[<Module>]` |
| `ctx.theme` | the merged theme tree, read-only |
| `ctx.isStudio` | boolean |
| `ctx.env` (v1.7.0) | the same table as `StudWork.env` |
| `ctx.flags` (v1.7.0) | the same table as `StudWork.flags` ([environments](kits/environments.md)) |
| `ctx.data.ordered(name)` (v1.7.0) | an ordered store per module: `get`, `set`, `increment`, `update`, `remove`, `top`; return `(ok, value \| reason)`, yield, never raise for a platform failure (§23.3) |
| `ctx.data.sortedMap(name)` (v1.7.0) | a MemoryStore sorted map per module: `get`, `set`, `update`, `remove`, `range`; budgeted and memory-charged per module (§23.4) |
| `ctx.data.census()` (v1.7.0) | `{ servers, players, peakPlayers, at }?`, nil until the first census read (§23.5); limits in `GameConfig.storeBudgets` |
| `ctx.services.get(name)` (v1.7.0) | an engine service a module may use (`BadgeService`, `TextService`, `UserService`, `LocalizationService`, `Players`); replaceable by a fake in specs (§23.6) |
| `ctx.openCloud` (v1.7.0) | `available(secret) -> boolean`, `request({ secret, method, path, body? }) -> (ok, status?, body?)`; deny by default through `ServerConfig.openCloud`, store and config families refused (§23.7) |
| `ctx.text` (v1.7.0) | `format(player, key, args?) -> string` (the player's language), `english(key, args?) -> string` (§23.9) |

## Save data

- `ctx.data.get(player)` returns a frozen read-only view of your section, in every environment.
- `ctx.data.update(player, fn)` is shorthand for a `ctx.tx` that touches only your section. It
  must not yield.
- New players get `data.default`. A section missing top-level keys gets them from the default.
- **Migrations:** `data.version` is the current version; `migrations/NNN_<label>.luau` returns
  `function(old) -> new` and turns version NNN-1 into NNN. They run on load, in order, before the
  section is used; `data.sanitize` runs after them. If a migration errors or returns a non-table,
  nothing is saved and the player gets the friendly kick with their data kept. A save written by
  newer code (a higher version) is left untouched. `tools/make-migration` writes the next one,
  bumps `data.version` (a literal, or the literal a `Save.VERSION`-style reference comes from) and
  maps `migrations/` in the game's project ([generators.md](generators.md#toolsmake-migration)).
- A disabled module's section is carried through saves as-is. `_framework._owners` records which
  module created each section; another module claiming the key is a load error unless it declares
  `data.adopts = "<OldModule>"`.
- Keys starting with `_` belong to the framework.

## Transactions

```lua
ctx.tx(player, function(tx)
	ctx.depsTx[Economy].grant(tx, 100, "quest")   -- Economy writes its own section
	local mine = ctx.section(tx)                    -- yours
	mine.done[questId] = true
	tx.after(function() ctx.net.feedback(player, "toast", "Quest done!") end)
end)
```

- `tx` is a sealed handle: `tx.player`, `tx.after(fn)`, `tx.retryLater(reason?)` (purchases), and
  nothing else. There is no `tx.data`.
- Write only through the tx: `ctx.section(tx)` (your section) and dependencies' `txApi`. Side
  effects go in `tx.after`, which runs once the change commits.
- Never yield inside. One tx per player at a time: calling a mutating API for a different player
  from inside a tx errors; do that in `tx.after`.
- If `fn` errors, nothing is committed and the error propagates to the caller. `ctx.tx` returns
  `false` without running `fn` when the player's data isn't loaded, and `false` after
  `tx.retryLater()`. Otherwise it returns `true` and `fn`'s result.

## Extensions and signals

An extension is a named hook a module offers its dependents. Register hooks in `init`:

```lua
-- the offering module's server part
local removed = StudWork.hook()
return {
	extensions = { onItemRemoved = removed.register },
	-- later, inside its own tx: removed.fire(tx, player, instance)
}

-- a dependent (optional = { Inventory })
function M.init(ctx)
	if ctx.isEnabled(Inventory) then
		ctx.depsExt[Inventory].onItemRemoved(function(tx, player, instance)
			local mine = ctx.section(tx) -- the DEPENDENT's section, inside Inventory's tx
		end)
	end
end
```

The hook runs inside the triggering module's transaction, and `ctx.section(tx)` is bound to the
module that registered it, so each hook writes only its own section. The kits' extensions
(`Inventory.onItemRemoved`, `Rebirth.resetStep`, `Mail.registerKind`) are on the kit pages.

Signals are part of a module's API: `ctx.deps[Economy].signals.CurrencyChanged:Connect(fn)`.
Connections return `{ Disconnect }`; handlers run in pcall, in connection order.

Publishing a signal: `ctx.signals.new` is only reachable from `init`, but the framework copies
`api` (and a plain `api.signals` table) before `init`. So make `api.signals` a table that exists
by identity before `init` and serves what `init` creates: the kits use a small proxy with a
metatable (`packages/kits/base/Plot/server/SignalTable.luau`, or the `__index` proxy in
`packages/kits/economy/Economy/server/init.luau`) and assign `signals.X = ctx.signals.new("X")` in
`init`. Or offer `api.onSomething(fn)` built on `StudWork.hook()`, as the example module does
(`onNewBest`).

## Purchases

The framework owns `MarketplaceService.ProcessReceipt`. A module registers handlers:

```lua
function M.init(ctx)
	ctx.shop.onProduct("CoinPack", function(tx)
		assert(tx.use(Economy).grant(1000), "grant failed")
	end)
	ctx.shop.onProduct("EggRoll", function(tx)
		local def, info = tx.use(Rarity).roll("Egg")
		if info.reason == "restricted" then
			assert(tx.use(Inventory).addItem("crystal"), "inventory full") -- fixed, non-random fallback
			return
		end
		assert(def and info.ok, info.reason or "roll failed")
	end)
	ctx.shop.onPassOwned("DoubleCoins", function(player) ... end)
end
```

- `product`/`pass` is a name from `GameConfig.products` or a numeric id.
- `tx.use(Ref)` exposes that module's `purchaseOps`, bound to the purchase tx.
- The grant and the receipt record commit in one save; `PurchaseGranted` is returned only after
  it. If the handler errors or calls `tx.retryLater()`, nothing is granted and Roblox retries
  later. Side effects go in `tx.after`.
- `tx.paid` is set by the framework. Items granted in a purchase get a `paid:` source tag
  automatically.
- `ctx.shop.ownsPass(player, pass)`: every `products.passes` entry is looked up at join; the join
  waits for the answers at most `GameConfig.shop.passPrefetchTimeout` seconds (default 2, range
  0-5; v1.6.1) before the save loads, slower lookups finish in the background. Inside a
  transaction an answer that isn't known yet (pending, failed, or a pass never looked up) is never
  guessed (v1.6.1): in a purchase handler the receipt is retried (NotProcessedYet, nothing
  granted); anywhere else (a `capBonus`, a `rateFactor`, a module action) it errors
  (`ctx.shop.ownsPass yields: call it outside a transaction`) and the transaction is refused.
  Outside a transaction it yields and looks the pass up.

## Random outcomes: Compliance

Every random outcome a player can get from a registered source goes through the framework:

```lua
ctx.compliance.registerRandomSource("Chest", {
	odds = function(player) return oddsDetail end,          -- the full disclosure
	sample = function(player, luck, tx) return outcome end, -- picks ONE outcome
	luckDisclosed = true,
})
local ok, outcome, reason = ctx.compliance.roll(tx, "Chest", luck)              -- free
local ok2, outcome2, reason2 = ctx.compliance.spendForRoll(tx, "Gems", 100, "Chest") -- priced
```

- `roll`/`spendForRoll` are the only way to get an outcome from a registered source; the policy
  check, the luck rule and the sample happen in one call.
- `GameConfig.compliance.paidCurrencies` lists currencies bought with Robux. Spending one is only
  possible through `spendForRoll`, which spends and rolls in the same transaction.
- Unknown policy: `tx.retryLater()` inside a purchase, `(false, nil, "policy_unknown")` outside.
  Restricted player: `(false, nil, "restricted")`; grant a fixed non-random fallback.
- Luck on a paid roll is refused unless the source discloses luck and the player was sent exactly
  those odds. See [guardrails](guardrails.md).

## Networking and actions

Client -> server requests are **actions**, declared in the server part:

```lua
actions = {
	claim = { limit = { rate = 2, burst = 4 }, handler = function(player, questId: string) ... end },
	reroll = function(player) ... end, -- a bare function gets the default limit (4/s, burst 8)
},
net = require(script.Net.Generated), -- the module's Blink server module (optional)
```

The framework routes, rate-limits and `pcall`s every action, drops calls from players who left,
and holds calls until the player's data is loaded. Blink validates wire types; **your handler
validates ownership, ranges and rules.** An action finds its Blink event by name (`claim` or
`Claim`) in the module's `net`, or `event = <Blink event>` in the spec.

On the client, the client part declares the same names (`actions = { "claim" }` with its client
`net`), and code calls `StudWork.use(Quests).actions.claim(id)`.

Server -> client: `ctx.net.fire(player, event, ...)` / `fireAll(event, ...)` on the module's own
Blink events; `ctx.net.feedback(player, "toast" | "pop" | "item", text, rarity?)` for the built-in
cosmetic feedback. Raw `RemoteEvent`/`RemoteFunction`/`OnServerEvent` are forbidden (lint).

Blink files: `tools/net` compiles every `.blink` file under `packages/framework`, `packages/kits`,
`examples/` and `games/` (game-local modules included) and writes the generated `Net.luau` files,
which are committed. Run it after changing a `net.blink`.

## Replication and client state

```
state.modules.<Name> = { data = { <data.replicate fields> }, extra = { <ctx.replicate keys> } }
```

- `data`: the fields in `data.replicate` (minus `serverOnly`) from the module's own section, sent
  when that section changes.
- `extra`: `ctx.replicate.set(player, key, value)` for one player, `ctx.replicate.setAll(key, value)`
  for everyone (a player's own `set` wins over `setAll` for the same key). Values must be
  wire-safe (no Instances or functions).
- Players only ever receive their own state.

## The client part

`client/init.luau` (optional):

```lua
return {
	init = function(ctx) end,  -- ctx = { name, config, gameConfig }
	start = function(ctx) end,
	api = { ... },             -- merged into StudWork.use(ref) on the client
	actions = { "claim" },     -- or { claim = <Blink client event> | "<EventName>" | true }
	net = <generated Blink client module>,
}
```

`StudWork.use(ref)` on the client returns `{ actions, state, ...api }`, frozen. `state()` is the
module's slice (a Charm selector live: bind it with `ReactCharm.useAtom`). An unknown action errors
`"<Module> has no client action '<name>'"`. Screens and HUD widgets: [theme guide](theme.md).

## Items and item fields

Base item fields (framework): `id`, `name`, `rarity?` (a tier name), `model?`, `icon?`, `tags?`,
`source?`, `keepOnRebirth?`. Modules add namespaced fields with `itemFields`; Economy adds
`item.economy.incomePerSec` and `mutation.economy.incomeMultiplier`. A namespace no enabled module
declared is a boot error. Items exist only through `GameConfig.items`, validated once at boot;
registering items after start is not supported …

## Rojo layout

| Part | Rojo path |
|---|---|
| `module.luau` | `ReplicatedStorage.Modules.<Name>.module` |
| `client/` | `ReplicatedStorage.Modules.<Name>.client` |
| `migrations/` | `ReplicatedStorage.Modules.<Name>.migrations` (next to `module.luau`: `script.Parent.migrations`) |
| `shared/` | `ReplicatedStorage.Modules.<Name>.shared` |
| `server/` | `ServerScriptService.Modules.<Name>` (a direct child; there is no `<Folder>.<Name>` scan) |

The loaders find parts by name (`ref.server`, `ref.client`; module-api.md §19.9): a server part
that is a factory (`new`, no `init`/`start`) is built fresh per runtime, and a `Net` child
(generated from `net.blink`) becomes the part's `net`. The game's own module is mapped as
`ReplicatedStorage.GameModule.module` + `ServerScriptService.Modules.<GameModuleName>`.
`tools/make-module --game` writes these entries. Since v1.3.1 the built-in kits use the same
layout (`packages/kits/<kit>/<Module>/`), and `tools/sync-projects` generates their entries in
every project (lint fails on drift).

## Testing

Modules ship Lune specs that run without Studio, through `StudWork.test` (module-api.md §15;
Lune only, never in a game build):

```lua
local StudWork = require(game:GetService("ReplicatedStorage"):WaitForChild("Framework"))
local h = StudWork.test.harness({
	modules = { Economy, Quests },               -- refs; kit modules run their real server parts
	servers = { Quests = QuestsServer },         -- inject server parts by name (wins over the kit's)
	config = { Quests = { dailyCount = 5 } },
	items = { ... }, products = { ... },
})
local p = h:addPlayer({ userId = 1, data = nil }) -- mock player + mock store (seed a save with `data`)
h:tick(10)                                        -- advance the shared ticker and the clock
h:action(p, Quests, "claim", "q1")                -- through the action routing
h:rejoin(p, { secondsAway = 3600 })               -- save -> release -> load -> migrate
h:fire(p, "StateInit"); h:state(p)                -- the replicated state that player was sent
h:receipt({ ... })                                -- MarketplaceService.ProcessReceipt
h:purchase(p, "CoinPack", { retries = 2 })        -- a receipt, re-delivered while NotProcessedYet
h:saved(p)                                        -- what is in the mock store (sectioned save)
expect(h:use(Quests).doneCount(p)).toBe(1)
-- StudWork.test.boot(opts) -> (h?, err?) returns a boot error instead of raising
-- StudWork.test.memoryStore(): one store several harnesses share; store.failNext(n) injects failures
```

v1.7.0 harness options: `env`, `placeId`, `universeId`, `services`, `openCloud`, `secrets`, `locale`,
`translator`, `storeBudgets`, `census`, `strings`, `localization`; `h:orderedStore(module, name)` and
`h:sortedMap(module, name)` return the in-memory store behind a module's store; the fakes are in
`StudWork.test.fakes` (module-api §23.10).

A spec for a **game** module (the game's own module against the kits: the harness options, every
harness method, `h:console`, `h:action` for a client's request, `h:sent` for what the server sent a
client, the fake Workspace and Players) has its own page: [testing.md](testing.md).

Run them with `tools/test <folder>`. Several servers, real ProfileStore session locks, crashes,
latency and DataStore failures: `StudWork.test.sim` (`sim.world()`, `sim.server(world)`,
`server:use(Ref)`, `server:section(p, key)`, `sim.saved(world, userId)`; see
`packages/framework/test/sim/README.md`). Each generated game has `src/server/Boot.spec.luau`, which
boots the whole game with the real kit modules in the sim.

## Config keys added in v1.7.0

All optional and top level in `GameConfig` unless noted (module-api §23): `environments` (test and
live place and universe ids; generated into `src/shared/Config/Environments.luau` by
`tools/sync-projects`), `flags`, `flagOverride`, `storeBudgets`, `strings`, `localization`;
`ServerConfig.openCloud` (secrets and allow-list, server only) and `ServerConfig.flags` (hidden
flags). The four kit modules (Leaderboards, Badges, Notifications, TextFilter) are normal modules
with their own `config.<Name>` ([kit contract](kit-contract.md)).
`Notifications.suggestOptIn(player, reason) -> (boolean, reason?)`: whether a prompt was requested,
and why not (reasons in [the Notifications page](kits/notifications.md)).

## Errors you will see

| Message | Meaning |
|---|---|
| `<Name> is not enabled in GameConfig.modules` | you called a module the game doesn't list |
| `invalid GameConfig.modules: - module '<A>' requires '<B>': add <B> to GameConfig.modules` | a hard dependency isn't listed (cycles are named the same way) |
| `<Owner>: '<Name>' is not a declared dependency; add it to dependsOn or optional` | `ctx.deps[X]` for an undeclared X |
| `<Module>.api.<fn> called during init` | move cross-module calls to `start` |
| `<Module>.init yielded` / `start yielded` | no yielding during boot; use `task.spawn` inside handlers |
| `invalid GameConfig: - config.<Name>.<key> ...` | config doesn't match the module's schema |
| `data.replicate = true is not supported` | list the fields |
| `save section '<key>' belongs to module '<owner>'` | a data.key collision; rename or `data.adopts` |
| `[StudWork] StudWork.<X>: X is a framework internal` | use the scoped `ctx.<x>` in a module |
