# StudWork module API (design draft for core v1.3.0)

Status: **draft** written by an AI coding agent (2026-11-10) from the `core-contract-v1.2` code on
`main`. In Phase 0, the lead checks it against the code, revises it, records every change in
`docs/decisions.md`, has it reviewed by a fresh subagent, and then freezes it. Read
`docs/philosophy.md` first.

Goal: one public API that **every** module uses, built-in kits and third-party modules alike.
That's what turns core from a fixed set of services into a framework.

---

## 0. What has to change, and why

The v1.2 code already has the right ideas, but they're **closed lists** that only core can edit:

| v1.2 mechanism (closed) | Where | v1.3 replacement (open) |
|---|---|---|
| `Modules.SPECS`, `MODULE_ORDER`, `ModuleLoader.BOOT_ORDER` | `shared/Modules.luau`, `server/ModuleLoader.luau` | Each module declares `dependsOn`; the loader topo-sorts registered modules (§2, §3) |
| `Modules.API` name lists; `Core.<Name>` facade | `shared/Modules.luau`, `shared/init.luau` | `server.api` / `client.api` declared by the module; reached with `StudWork.use(ref)` (§4) |
| `Context.ServerServices` with `*Internal` types (`grantInto`, `addInto`, `rollInto`, `sendInto`, `addResetStep`, `onRegistered`, `sectionVersion`) | `server/Context.luau` | `server.txApi` (operations that run inside a transaction) plus `server.extensions` (hooks for dependents), both given only to declared dependents (§5, §8) |
| One flat `PlayerData` with one `schemaVersion`; per-game table with its own `_version` | `Types.PlayerData`, `Data/Schema.luau` | **A save section per module**, each with its own default, version and migrations; this generalises today's game-table pattern (§6) |
| `PurchaseTx.grant/addItem/roll` hardwired to Economy/Inventory/Rarity | `Types.PurchaseTx`, `Shop` | Modules contribute purchase operations; `tx.use(ref)` (§7) |
| `Modules.CLIENT_ACTIONS` and one core `.blink` file | `shared/Modules.luau`, `shared/net/core.blink` | Modules declare their own actions, with their own Blink file and rate limits (§9) |
| `ReplicatedState` fields fixed (`ratePerSec`, `odds`, `mailbox`…) | `Types.ReplicatedState`, `Replication` | Replicated state namespaced per module (§10) |
| `BalanceConfig.income/rarityTables/...` | `Types.BalanceConfig` | Config namespaced per module: `GameConfig.config.<ModuleName>`, validated against the module's schema (§11) |
| `ItemDef.incomePerSec` in the base type | `Types.ItemDef` | Base item fields plus **namespaced item fields** declared by modules (§12) |
| Fixed HUD, palette, sounds, rarity tiers | client `Hud`, `Palette`, `Sounds`, `RarityTiers` | Theme tokens contributed by modules; HUD made of widget slots (§13) |
| Odds disclosure and the luck rule live in Rarity | `server/Rarity` | Moved to the framework's **Compliance** service, so third-party random sources are covered too (§14) |

**Keep:** `Tx.run`, Data's transaction rules (working copy, commit only on success, no yielding, no nesting), frozen public APIs, the disabled-module error messages, the pre-start request queue, boot that fails closed (N7), and every guardrail.

---

## 1. Anatomy of a module

Each module is one folder with three parts, so server code never replicates to clients:

```
kits/economy/                      (or examples/modules/leaderboard/, or games/<g>/modules/<m>/)
├─ module.luau          ← shared definition (manifest). Required on both sides. No server logic.
├─ server/init.luau     ← server implementation: init/start + api/txApi/extensions
├─ client/init.luau     ← optional client implementation: init/start + api, widgets, screens
├─ net.blink            ← optional: this module's client↔server messages
├─ migrations/          ← 001_init.luau, 002_*.luau …
├─ tests/               ← Lune specs (run without Studio)
└─ README.md            ← config keys with defaults, API, hooks, save data shape
```

Rojo mapping (`tools/make-module` and the generators produce this):

| Part | Goes to |
|---|---|
| `module.luau`, `net.blink` (client half), `client/` | `ReplicatedStorage.Modules.<Name>` |
| `server/`, `net.blink` (server half) | `ServerScriptService.Modules.<Name>` |

The loader finds a module's server and client parts **by name** in those folders.

---

## 2. The definition (`module.luau`)

```lua
--!strict
local Framework = require(game:GetService("ReplicatedStorage").Framework)
local Collection = require(script.Parent.Parent.collection.module) -- refs to dependencies

export type API = {                -- the server API other code reaches with StudWork.use(Economy)
	grant: (player: Player, amount: number, reason: string, currency: string?) -> boolean,
	spend: (player: Player, amount: number, reason: string, currency: string?) -> boolean,
	balance: (player: Player, currency: string?) -> number,
	getRate: (player: Player) -> number,
	-- …
}
export type TxAPI = {              -- operations that run inside a transaction (§5)
	grant: (tx: StudWork.Tx, amount: number, reason: string, currency: string?) -> boolean,
}
export type ClientAPI = { rate: () -> number, balance: (currency: string?) -> number }

return StudWork.defineModule({
	name = "Economy",              -- unique; PascalCase; also the config key and save-section owner
	version = "1.0.0",             -- the module's own semver
	framework = "^1.3.0",          -- compatible framework versions (checked at boot)
	dependsOn = { Collection },    -- hard dependencies (refs, not strings)
	optional = { },                -- soft dependencies: used only if the game enables them too

	config = {
		schema = { tickSeconds = "number", primaryCurrency = "string", paidCurrencies = "{string}?", … },
		defaults = { tickSeconds = 1, primaryCurrency = "Coins", multiplierStacking = "multiply" },
	},

	data = {
		key = "economy",           -- save section, owned only by this module
		version = 1,
		default = { currency = {}, multipliers = {} },
		migrations = script.Parent.migrations,  -- folder of NNN_*.luau: [toVersion] = fn(old) -> new
		replicate = { "currency" },             -- fields the owning client sees (true = all, false = none)
		serverOnly = { },                       -- fields that never replicate, even with replicate = true
	},

	itemFields = {                 -- extends ItemDef / Mutation under a namespace (§12)
		item = { economy = { incomePerSec = "number" } },
		mutation = { economy = { incomeMultiplier = "number" } },
	},

	theme = {                      -- theme tokens this module adds, with defaults (§13)
		sounds = { coin_tick = { id = 16480580213, volume = 0.35 } },
		colors = { currency = "#FFD23F" },
	},

	server = "Economy",            -- name under ServerScriptService.Modules (default = name)
	client = "Economy",            -- name under ReplicatedStorage.Modules (nil = no client part)
}) :: StudWork.ModuleRef<API, TxAPI, ClientAPI>
```

**Rules**
- `defineModule` only validates and freezes the table. It has no side effects, so requiring a module definition is always safe.
- Dependencies are **references** (required definitions), never strings. That gives typed access, and a typo becomes an error at require time.
- `name` must be unique among the enabled modules. Two modules declaring the same `data.key` is a boot error.
- `framework` is a semver range, and an incompatible module fails at boot with a clear message.

---

## 3. Lifecycle and boot

Game entry:

```lua
-- games/<g>/src/shared/Config/init.luau
local Kits = require(ReplicatedStorage.Kits)
return {
	gameId = "example-shop",
	modules = { Kits.Collection, Kits.Economy, Kits.Base, Kits.Social, Kits.Engagement,
	            require(ReplicatedStorage.Game.Modules.ClueGenerator) },
	config = { Economy = { tickSeconds = 1 }, Collection = { rarity = { preset = "standard7" } } },
	items = { … }, products = { … }, events = { … }, theme = { … },
}
-- server: StudWork.start(Config, ServerConfig)   client: StudWork.start(Config)
```

Boot steps (each side):
1. **Resolve.** Collect the listed modules and their **hard** dependencies, which must also be listed. Unlike v1.2, there's no auto-enabling: an explicit list keeps games honest. Then check names are unique, data keys are unique and framework versions are compatible. Topo-sort the result, breaking ties by list order. A cycle is a boot error that names the cycle.
2. **Validate config.** Merge `config.<Name>` over each module's defaults and validate it against its schema. Validate items against the base item fields plus every enabled module's `itemFields`. Merge the theme (§13). **All errors are collected and reported together**, as `ConfigValidate` does today.
3. **Framework init.** Data, Compliance, Policy, Shop, Net, Replication, Events, Analytics, Console, Theme.
4. **`init(ctx)`** for every module in order. No yielding, and no calls into other modules' APIs. Register handlers, actions and console commands here.
5. **`start(ctx)`** for every module in order. Connect events and start loops. Calling dependencies' APIs is now allowed.
6. **Framework start.** Data starts loading players, Replication starts, and Net releases its queued requests.

If any step throws, boot **fails closed**: every later call errors with the boot message, as N7 does today.

Lifecycle hooks on `ctx.lifecycle`, available to every module:

| Hook | When |
|---|---|
| `onPlayerLoaded(fn(player))` | After the player's save loaded and migrated, before Replication's first send |
| `onPlayerRemoving(fn(player))` | Before the final save. No yielding |
| `onTick(seconds, fn(dt))` | A shared, batched ticker. One loop for all modules, not one per module |
| `onShutdown(fn())` | On `BindToClose`, before the final saves are flushed |

---

## 4. Reaching other modules: `StudWork.use`

```lua
local Economy = require(ReplicatedStorage.Kits.Economy)
local economy = StudWork.use(Economy)        -- typed as Economy's API (server) / ClientAPI (client)
economy.grant(player, 10, "quest")
```

- `StudWork.use(ref)` returns the module's **frozen** public API for the current side.
- If the module isn't enabled, `use` returns an erroring proxy that says "Economy is not enabled in GameConfig.modules". It doesn't return nil.
- Calling `use` before `StudWork.start` errors.
- **Inside a module, use `ctx.deps`, not `StudWork.use`.** `ctx.deps` contains exactly the declared dependencies, so an undeclared dependency is a boot error and not a hidden coupling. A lint rule enforces this.
- `StudWork.Economy`-style sugar is generated for **every** enabled module, built-ins and third-party alike. It's untyped, a convenience for the command bar and console. Typed code uses `StudWork.use`.

---

## 5. `ctx`: everything a module may use, and nothing else

```lua
type ModuleContext = {
	name: string,
	config: any,                         -- this module's merged + validated config (frozen)
	gameConfig: GameConfigPublic,        -- read-only: gameId, items, products, events (no other modules' config)
	deps: { [ModuleRef]: API },          -- declared dependencies' public APIs:  ctx.deps[Economy]
	                                     -- (hard + optional; a disabled optional dep is an erroring
	                                     -- proxy, so check ctx.isEnabled first). A module's signals
	                                     -- are part of its API: ctx.deps[Economy].signals.CurrencyChanged
	depsTx: { [ModuleRef]: TxAPI },      -- declared dependencies' txApi
	depsExt: { [ModuleRef]: Extensions },-- declared dependencies' extensions (§8)
	isEnabled: (ref: ModuleRef) -> boolean,  -- for optional dependencies

	data: ScopedData,                    -- this module's save section only (§6)
	tx: (player: Player, fn: (tx: Tx) -> R) -> (boolean, R?),   -- Tx.run across modules (§5.1)
	section: (tx: Tx) -> any,            -- this module's writable section inside a tx

	net: ModuleNet,                      -- this module's actions + server→client events (§9)
	replicate: ModuleReplication,        -- this module's replicated state (§10)
	compliance: Compliance,              -- odds registry + paid-roll rule (§14)
	policy: Policy, analytics: Analytics, events: Events, shop: ShopForModules,
	signals: Signals,                    -- this module's own signals + framework signals
	console: ModuleConsole,              -- commands are auto-prefixed: "economy grant …"
	lifecycle: Lifecycle,
	log: Logger,                         -- tagged "[Economy]"
	theme: ThemeRead,                    -- resolved theme tokens (read-only)
	isStudio: boolean,
	serverConfig: any,                   -- server-only: this module's part of ServerConfig
}
```

### 5.1 Transactions across modules

The v1.2 `*Into` functions become each module's **`txApi`**. The rules stay the same: write only to
tx data, run side effects with `tx.after` once the transaction commits, never yield.

```lua
-- Economy server
local function grantInto(tx, amount, reason, currency)
	local s = ctx.section(tx)            -- Economy's OWN section in this transaction
	s.currency[currency or ctx.config.primaryCurrency] += amount
	tx.after(function() ctx.signals.CurrencyChanged:Fire(tx.player, ...) end)
	return true
end
return { init = …, start = …, api = { grant = grant, … }, txApi = { grant = grantInto } }

-- Another module (declared dependsOn Economy) combines operations atomically:
ctx.tx(player, function(tx)
	ctx.depsTx[Economy].grant(tx, 100, "quest")
	local mine = ctx.section(tx); mine.questsDone += 1
end)
```

`tx` is opaque to modules. `ctx.section(tx)` is the **only** way to reach section data inside it,
and it returns only the calling module's own section, because each module's `ctx.section` is bound
to its own `data.key`. That's how "modules stay in their own data" is enforced by construction,
not by convention.

---

## 6. Save data: a section per module

```
Profile.Data = {
	_framework = { schemaVersion = 2, firstJoin = …, lastSeen = …, purchases = {…}, funnel = {…} },
	_versions  = { economy = 1, collection = 3, quests = 1 },
	economy    = { … },       -- owned by Economy
	collection = { … },       -- owned by Collection
	quests     = { … },       -- owned by a third-party module
	["example-shop"] = { … },   -- the game's own section (today's PlayerData.game[gameId])
}
```

- **Each module migrates its own section** with its migrations folder. This generalises today's game-table `_version` pattern.
- **If any migration fails, nothing is saved** and the player gets the friendly kick, with the same guarantee as Decision 1 in v1.1.
- **The framework's `_framework` section** (purchases, funnel, first and last seen) has its own migrations.
- **Sections of modules that aren't enabled are kept untouched.** Switching a module off must never delete data. A disabled module's section is carried through saves as-is.
- **`ScopedData` API:** `get(player)` returns a frozen read-only view of the module's own section. `update(player, fn(section))` is shorthand for `ctx.tx` touching only this section. `isLoaded(player)`, `onLoaded(fn)`.
- **Per-section versions for Replication** are kept as today's `sectionVersion` (M2), now keyed by module.
- **The game's own section** is simply the game acting as a module: `games/<g>` gets an implicit module named after `gameId`, with `config.data` as today. That's not special either.
- **Moving v1.2 saves:** a `_framework` migration splits a v1.2 flat save into sections. There are no published games yet, but write it anyway and test it. It proves the migration path works.

---

## 7. Purchases (Shop) for modules

The guardrail stays in the framework. Modules only add operations.

```lua
StudWork.use(Shop).onProduct("CoinPack1000", function(tx: PurchaseTx)
	tx.use(Economy).grant(1000)                    -- Economy's purchaseOps.grant
	tx.use(Collection).addItem("GoldenPebble")     -- source auto "paid:<product>"
end)
```

- A module declares `server.purchaseOps`: functions with the shape `(tx, ...)` that are safe inside a receipt transaction. `tx.use(ref)` exposes them, typed.
- The Shop wrapper keeps the v1.1 contract:
  - one non-yielding `Data.update`,
  - the receipt is recorded in `_framework.purchases` in the same commit,
  - `PurchaseGranted` only after the save,
  - `tx.retryLater`, `tx.after`.
- `tx.paid = true` and `tx.paidRandomRestricted` are set by the framework and can't be changed.
- Random purchase ops must go through `ctx.compliance` (§14), and the framework checks that they did.

---

## 8. Extensions: how modules hook into each other

Today's `Rebirth.addResetStep` and `Items.onRegistered` are internal-only. They become declared
**extensions**: named hooks a module offers to its dependents.

```lua
-- Rebirth (Economy kit) server:
extensions = {
	resetStep = function(id: string, fn: (tx: Tx, player: Player) -> ()) … end,  -- runs inside Rebirth's tx
}
-- Base kit (Plot), which declares optional = { Economy }:
if ctx.isEnabled(Economy) then
	ctx.depsExt[Economy].resetStep("plot", function(tx, player) ctx.section(tx).displayed = {} end)
end
```

- Extensions are documented in the module's README alongside its API.
- Third-party modules can offer extensions and use other modules' extensions on the same terms.
- Extensions run with the hooked module's guarantees, so a reset step runs inside Rebirth's single transaction. Each reset step can write only its own section, because `ctx.section(tx)` enforces that.

---

## 9. Networking and actions

- **Each module may ship a `net.blink` file.** `tools/net` compiles every module's Blink file, for the framework, kits, examples and the game, into per-module generated code.
- **Client→server actions** are declared in the server part:

```lua
actions = {
	upgrade = { limit = { rate = 4, burst = 8 }, handler = function(player, upgradeId: string) … end },
}
```
- The framework routes, rate-limits and `pcall`s each action. It drops calls from players who have left, and blocks calls until the player's data is loaded. Blink validates wire types; **handlers validate ownership, ranges and rules**.
- On the client, `StudWork.use(Economy).actions.upgrade(id)` comes from the module's client part. Calling an action of a module that isn't enabled gives the clear error.
- **Server→client events** use `ctx.net.fire(player, event, ...)` and `ctx.net.fireAll(event, ...)` on the module's own Blink events.
- **Raw `RemoteEvent`, `RemoteFunction` and `OnServerEvent` are forbidden** in modules and games. The v1.2 guardrail stays.

---

## 10. Replication and client state

```
StudWork.Client.state() = {
	loaded = true,
	framework = { … },                          -- activeEvents, paidRandomRestricted, theme version
	modules = {
		Economy = { data = { currency = {…} }, extra = { ratePerSec = 12.5, multiplier = 1.5 } },
		Collection = { data = { inventory = {…} }, extra = { odds = {…} } },
		Social = { extra = { mailbox = {…} } },
	},
}
```

- **`data`:** the fields listed in `data.replicate`, minus `serverOnly`. These are diffed by section version, as M2 does today.
- **`extra`:** set with `ctx.replicate.set(player, key, value)` and `setAll(key, value)`, namespaced to the module automatically. `ctx.replicate.sent(player, key)` stays available, for the luck-disclosure check.
- **Client selectors:** `StudWork.use(Economy).state()` returns that module's slice as a Charm atom selector. UI code never digs through `modules.X` by hand.

---

## 11. Config

- **Each module's config lives under `GameConfig.config.<Name>`.** It's merged over the module's `defaults` and validated against its `schema`. Unknown keys produce a warning, so typos get caught.
- **The schema language** stays the small type-string format that ConfigValidate already handles, extended where needed: optional `?`, lists, maps, enums, number ranges. Every key carries a description and a default, so the module's README can be generated from it.
- **Framework-level config stays at the top level:** `gameId`, `modules`, `items`, `products`, `events`, `theme`, `client`, `data` (the game's own section).
- **`ServerConfig.<Name>`** is server-only config, for admin IDs and the like. It's never replicated (L5).

---

## 12. Items and item fields

**Base `ItemDef`** (in the framework, so items exist even without any kit; open question 1 in §17 may move this into Collection):

```lua
{ id: string, name: string, rarity: string?, model: string?, icon: string?, tags: {string}?,
  source: string?, keepOnRebirth: boolean?, [namespace: string]: { … } }
```

- `rarity` is a **string** validated against the active tier list (§13). It's not a fixed union type any more.
- Modules add namespaced fields: Economy adds `item.economy.incomePerSec` and `mutation.economy.incomeMultiplier`. The validator rejects namespaces that no enabled module declared.
- A collection-only game: items without an `economy` table earn nothing, and that's valid.

---

## 13. Theme, rarity look, HUD and screens

**The theme is one merged tree:**

1. framework defaults (`framework-default` preset),
2. then each enabled module's `theme` contribution,
3. then the game's `GameConfig.theme`.

```lua
theme = {
	preset = "framework-default",            -- or a game-supplied preset table
	colors = { accent = "#FF5DA2" },          -- partial overrides deep-merge
	fonts = { display = "rbxasset://fonts/families/LuckiestGuy.json" },
	metrics = { cornerRadius = 8 },
	sounds = { coin_tick = { id = 123, volume = 0.3 } },
	rarity = { preset = "standard7" } or { tiers = { { id = "Bronze", color = "#CD7F32", soundKey = "r1" }, … } },
}
```

- **Rarity tiers are owned by Collection,** which contributes `theme.rarity` and validates item rarities against it. Tier order is the list order.
- **Every UI component and Feedback call reads theme tokens.** No colours, fonts, sizes or sound IDs are hardcoded in UI code, and a lint rule checks for hex colours and asset IDs outside theme files.

**HUD made of slots:**
- The default HUD is a layout with named slots: `topLeft`, `topCenter`, `topRight`, `left`, `right`, `bottom`.
- Modules contribute widgets: Economy adds a currency counter and rate, Social adds the mailbox badge, the game adds a next-goal widget.
- A game can:
  - replace or remove any widget: `client.hud.widgets = { ["Social.mailbox"] = false }`,
  - replace the whole layout: `client.hud = MyHud`,
  - or turn the HUD off: `client.hud = false`.

**Screens:**
- `UI.registerScreen(name, component)` and `UI.open(name, props)`.
- Modules register default screens (Collection registers `Odds` and `Inventory`; Social registers `Mailbox`).
- A game replaces one by registering a screen with the same name.

---

## 14. Compliance (framework service)

The odds disclosure registry and the paid-roll luck rule move out of Rarity into the framework, so
**every** random source is covered, including third-party ones.

```lua
ctx.compliance.registerRandomSource(id, { odds = fn(player) -> OddsDetail, luckDisclosed = boolean })
ctx.compliance.checkPaidRoll(tx, sourceId, luck) -> (ok, reason)   -- policy + luck + disclosure
ctx.compliance.tagPaid(source)                                    -- "paid:<id>" / "paidcur:<id>"
```

- Collection's Rarity calls these functions, and so must any third-party random source.
- The framework replicates the disclosed odds and provides the `OddsTable` screen for any registered source.
- **What is enforced:**
  - Shop marks every purchase transaction as paid.
  - A purchase op that rolls without calling `checkPaidRoll` first is refused at commit, because the framework tracks whether that check ran during the transaction.
  - Spending a `paidCurrencies` currency inside a transaction marks it as paid in the same way.
- **What can only be guided:** arbitrary module code could still invent randomness outside these APIs. The documentation, the generator template and a lint heuristic (`math.random` or `Random.new` in a function that also spends a paid currency) steer authors to Compliance. Say this honestly in the guardrails documentation.

---

## 15. Testing modules

`StudWork.test` runs in Lune, with no Studio needed:

```lua
local h = StudWork.test.harness({ modules = { Collection, Economy, MyModule }, config = { … } })
local p = h:addPlayer({ userId = 1, data = nil })      -- mock player + mock ProfileStore
h:tick(10)                                             -- advance the shared ticker
h:action(p, MyModule, "doThing", "arg")                -- goes through rate limit + validation
h:purchase(p, "CoinPack1000", { retries = 2 })         -- receipt retry simulation
h:rejoin(p, { secondsAway = 3600 })                    -- save → load → migrate → offline
expect(h:use(Economy).balance(p)).toBe(…)
```

- These are the v1.2 multi-player test helpers (agent C), promoted to public API.
- Every module generated by `tools/make-module` comes with a passing harness test.

---

## 16. How today's code maps to the kits

| Kit | Modules | Notes |
|---|---|---|
| **framework** | Data, Net, Replication, Shop + Tx, Policy, Compliance, Events, Analytics, Console, Theme, Input, Feedback, UI runtime (screens, HUD slots) | Always on. `Core.Net` (GameNet) becomes module and game actions |
| **collection** | Items, Inventory (cap, transfer, gift), Rarity (tiers, pity, mutations, luck) | Contributes `theme.rarity`, the Odds and Inventory screens, and purchase ops `addItem` and `roll` |
| **economy** | Economy, Upgrades, Rebirth, Offline | Adds the item and mutation fields, the currency and rate widgets, the purchase op `grant`, and the extension `Rebirth.resetStep` |
| **base** | Plot | Optional dependency on Economy (reset step). Plot model and tag set in config |
| **social** | Friends, Mail (mailbox, outbox, gifting via Collection's transfer) | Contributes the mailbox widget and screen |
| **engagement** | Streak | Time zone and grace window in config |

Whether a kit is one module or several (`Kits.Economy` as one module versus `Economy`, `Upgrades`,
`Rebirth` and `Offline` as four) is open question 2.

---

## 17. Open questions for review

1. **Should `ItemDef` belong to the framework or the Collection kit?** Framework. (revised: keeping `{id, name, rarity, model, icon, tags, source, keepOnRebirth}` item-agnostic in
   the framework lets non-Collection kits (Base's Plot slot display, Social's gift payloads)
   reference an item id without pulling in Collection as a hard dependency. Collection still owns
   the rarity *tier list* and validates the `rarity` string against it (§13); it just doesn't own
   the shape.)
2. **How fine-grained should modules be inside a kit?** Finer modules (today's 11: Items,
   Inventory, Rarity, Economy, Upgrades, Rebirth, Offline, Plot, Friends, Mail, Streak), each a
   real `defineModule`, plus a `Kits.<Name>` bundle ref per kit that expands to its modules in
   dependency order. (revised: confirmed — finer modules preserve v1.2's existing hard
   dependency graph in `Modules.SPECS` exactly, which the existing tests already cover; one module
   per kit would force Inventory/Rarity/Upgrades/Rebirth/Offline to share one data section and one
   migrations folder, which is a bigger behavior change than this round allows.)
3. **Blink per module:** workable. (revised: `tools/net` already compiles one
   `core.blink` into three generated files per side; extending it to loop over every module's
   `net.blink` and emit `Modules/<Name>/{server,client}/Net/Generated.luau` is the same codegen
   repeated per file, so build time scales linearly with module count, not quadratically. The Rojo
   mapping already supports one project file per module folder (`server/`, `client/`) per §1.)
4. **Typing `StudWork.use`:** needs a generic signature, no fallback accessor needed. (revised: Luau's generic resolution through a table-returning function like
   `defineModule(...) :: ModuleRef<API, ...>` does carry the cast type to the call site under
   luau-lsp strict mode, confirmed against how `Context.luau`'s `*Internal` intersections already
   type-check today. `StudWork.use(ref)` needs a generic function signature
   `use<A, T, C>(ref: ModuleRef<A, T, C>): A` — straightforward in Luau. Each module's definition
   file already carries the `:: StudWork.ModuleRef<...>` cast per §2, so `StudWork.use` just
   forwards that type.)
5. **The compliance check at commit:** implementable. (revised: give `Tx` an internal,
   non-module-visible flag set only by `ctx.compliance.checkPaidRoll` and read only by Shop's
   commit path — the same pattern `EconomyInternal.grantInto` already uses to queue `tx.after`
   work invisibly to the calling module. No module can see or clear the flag, so it can't be
   spoofed from module code; only Compliance and Shop touch it.)
6. **Performance:** target kept — flag any regression over 20% against the v1.2 bench
   (0.64 ms/tick at 50×100), measured in Phase 2 step 7.
7. **The v1.2 save migration:** covered. (revised: confirmed each field has a clear new
   home — `displayed`→Base's `plot` section, `upgrades`→Economy's `economy` section,
   `pity`→Collection's `collection` section, `mail.outbox`/`mail.box`→Social's `social` section,
   `stats`/`funnel`/`purchases`/`firstJoin`/`lastSeen`→`_framework`, `game`→the game's own implicit
   module section. Write the `_framework` migration in Phase 0 step 4 and test it against a v1.2
   save fixture, since there's no published game yet to migrate for real.)

---

## 18. Sketch: a third-party module (`examples/modules/leaderboard`)

```lua
-- module.luau
return StudWork.defineModule({
	name = "SessionLeaderboard", version = "0.1.0", framework = "^1.3.0",
	dependsOn = {}, optional = { Economy },
	config = { schema = { stat = "string", top = "number" }, defaults = { stat = "earned", top = 10 } },
	data = { key = "sessionLeaderboard", version = 1, default = { best = 0 }, replicate = true },
	theme = { colors = { leaderboardGold = "#FFD23F" } },
	server = "SessionLeaderboard", client = "SessionLeaderboard",
})

-- server/init.luau
local M = {}
function M.init(ctx) M.ctx = ctx end
function M.start(ctx)
	if ctx.isEnabled(Economy) then
		ctx.deps[Economy].signals.CurrencyChanged:Connect(function(player, _, _, delta)
			if delta > 0 then ctx.data.update(player, function(s) s.best += delta end) end
		end)
	end
	ctx.lifecycle.onTick(5, function() ctx.replicate.setAll("top", M.topN(ctx.config.top)) end)
end
M.api = { best = function(player) return M.ctx.data.get(player).best end }
return M

-- client/init.luau registers a HUD widget into the "right" slot and a "Leaderboard" screen.
```

The example uses no internals, and it shows: its own config with defaults, its own save section,
an optional dependency and its signals, the shared ticker, replicated state, and a HUD
contribution. Every feature a built-in kit uses is available to it.
