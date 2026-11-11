# Concepts

## A game is a list of modules

```lua
-- games/<g>/src/shared/Config/init.luau
local Modules = ReplicatedStorage:WaitForChild("Modules")
return {
	gameId = "my-game",
	modules = {
		require(Modules:WaitForChild("Items"):WaitForChild("module")),
		require(Modules:WaitForChild("Inventory"):WaitForChild("module")),
		require(Modules:WaitForChild("Economy"):WaitForChild("module")),
	},
	config = { Economy = { primaryCurrency = "Coins" } },
	items = { { id = "pebble", name = "Pebble", rarity = "Common", economy = { incomePerSec = 1 } } },
	products = { passes = {}, devProducts = {} },
	events = {},
}
```

Both sides boot from it: `StudWork.start(Config, ServerConfig)` on the server and
`StudWork.start(Config)` on the client. Everything else (currency, inventory, plots, mail) is a
module that the game lists or leaves out. The framework itself (data, purchases, networking,
replication, compliance, policy, events, analytics, console, theme) is always on and is not a
module: you never list it.

## A module is a definition plus parts

| Part | File | Side | What |
|---|---|---|---|
| Definition | `module.luau` | both | `StudWork.defineModule({...})`: name, version, dependencies, config schema + defaults, save section, item fields, theme tokens. No logic, no side effects |
| Server part | `server/init.luau` | server | `{ init, start, api, txApi, extensions, purchaseOps, actions }` |
| Client part | `client/init.luau` | client | `{ init, start, api, actions }` (optional) |
| Messages | `net.blink` | both | optional: the module's own Blink events |
| Migrations | `migrations/NNN_*.luau` | server | one per save-section version |
| Tests | `tests/*.spec.luau` | Lune | through the framework harness |

`defineModule` returns a **ModuleRef**: a frozen, validated table. Refs are how modules name each
other: `dependsOn = { Items }`, `StudWork.use(Economy)`, `ctx.deps[Economy]`. Strings are refused,
so a typo fails when the file is required, not at runtime.

The built-in kits are eleven modules in five kits (Collection: Items, Rarity, Inventory; Economy:
Economy, Upgrades, Rebirth, Offline; Base: Plot; Social: Friends, Mail; Engagement: Streak). They use
the same API a third-party module gets ([philosophy §3](../philosophy.md)).

## The game is its own module

A game's gameplay code lives in `games/<g>/modules/<gameId>/` (`module.luau` + `server/init.luau`),
shaped like any other module. The framework adds it to `GameConfig.modules` by itself; its save
section key is the `gameId`. Its `dependsOn` lists the kit modules its code calls. This is how game
code gets `ctx.shop.onProduct`, `ctx.data`, `ctx.tx` and the rest: there is no other way in.
`src/server/Main.server.luau` only builds the world and calls `StudWork.start`.

## `ctx`: everything a module may use

Each module's `init(ctx)` and `start(ctx)` get a `ctx` scoped to that module: its merged config,
its own save section, the APIs of the modules it declared, its log tag, its console prefix, and the
framework services (net, replication, compliance, shop, events, analytics, policy, lifecycle). It
gets nothing else. Inside a module, use `ctx.deps[Ref]`, not `StudWork.use(Ref)`: an undeclared
dependency then fails loudly instead of hiding a coupling. Full list:
[module reference](module-reference.md#ctx).

## Save data: a section per module

```
Profile.Data = {
	_framework = { schemaVersion, firstJoin, lastSeen, purchases, funnel, _owners, ... },
	_versions  = { economy = 1, inventory = 1, sessionLeaderboard = 1 },
	economy    = { ... },            -- owned by Economy
	inventory  = { ... },            -- owned by Inventory
	["my-game"] = { ... },           -- the game's own module
}
```

- A module reads and writes **only its own section** (`ctx.data`, `ctx.section(tx)`). Everything
  else goes through other modules' APIs.
- Each section has its own version and migrations. If any migration fails, nothing is saved and
  the player gets a friendly kick with their data kept.
- A module you switch off keeps its section untouched; switching it back on finds the data.
- The first module to create a section is recorded as its owner, and another module claiming that
  key is a load error (unless it declares `data.adopts`).

## Transactions

`ctx.tx(player, fn)` runs one atomic change across modules: write only through the `tx` (your own
`ctx.section(tx)` and dependencies' `txApi`), run side effects in `tx.after`, never yield, never
nest. A purchase handler gets the same kind of `tx`, recorded together with the receipt.

## Boot

Each side, in order; any error stops the boot and every later call fails with that message:

1. **Resolve** the listed modules (refs only, every hard dependency listed, unique names and data
   keys, compatible `framework` ranges, a topological order with ties in list order, cycles named).
2. **Validate** every module's config (defaults merged with `config.<Name>`, checked against the
   schema), the items (base fields plus the listed modules' item fields) and the theme. All errors
   are reported together.
3. **Framework init.**
4. **`init(ctx)`** of every module, in order. No yielding, no calls into other modules' APIs.
5. **`start(ctx)`** of every module, in order. Dependencies' APIs are callable; still no yielding.
6. **Framework start.** Queued requests are released, players load, the shared ticker runs, and
   the Shop claims `ProcessReceipt` last.

## Client state

The server replicates, per player:

```
{ loaded = true,
  framework = { paidRandomRestricted, activeEvents, ... },
  modules = { Economy = { data = { currency = {...} }, extra = { ratePerSec = 2 } }, ... } }
```

`data` is the fields a module lists in `data.replicate` (from its own section); `extra` is what it
sets with `ctx.replicate`. On the client, `StudWork.use(Ref).state()` returns that module's slice.
