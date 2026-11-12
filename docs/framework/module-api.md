# StudWork module API (design, v1.3)

This is the design of the module API that StudWork v1.3.0 introduced, written against the v1.2
code it replaced. Sections 0–18 were frozen when v1.3.0 shipped; later additions are in §19 and
never change what §0–§18 say. Notes marked **Why:** give the reasoning behind a rule (they came
out of a design review). Decisions that were deferred, and why, are in
[decisions.md](../decisions.md). For the API as it is today, read the
[module API reference](module-reference.md); read the [philosophy](../philosophy.md) first.

Section numbers (§1, §19.9, …) are cited from code comments and other pages, so they stay stable.

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
| `MarketplaceService.ProcessReceipt = Shop.processReceipt` (`Shop/init.luau`) | `server/Shop` | The framework claims it exclusively in the last boot step and watches for replacement (§7.1) |

**Keep:** `Tx.run`, Data's transaction rules (working copy, commit only on success, no yielding, no nesting), frozen public APIs, the disabled-module error messages, the pre-start request queue, boot that fails closed, and every guardrail.

---

## 1. Anatomy of a module

Each module is one folder with three parts, so server code never replicates to clients:

```
kits/economy/Upgrades/             (or examples/modules/session-leaderboard/, or games/<g>/modules/<m>/)
├─ module.luau          ← shared definition (manifest). Required on both sides. No server logic.
├─ server/init.luau     ← server implementation: init/start + api/txApi/extensions
│                         (or a table with new() -> part: a fresh part per runtime, §19.9)
├─ server/Net.luau      ← GENERATED from net.blink (ServerOutput), only with a net.blink
├─ client/init.luau     ← optional client implementation: init/start + api, widgets, screens
├─ client/Net.luau      ← GENERATED from net.blink (ClientOutput), only with a net.blink
├─ shared/              ← optional: pure code both sides need
├─ net.blink            ← optional: this module's client↔server messages
│                         (RemoteScope "STUDWORK_<NAME>", ServerOutput "server/Net.luau",
│                         ClientOutput "client/Net.luau")
├─ migrations/          ← 001_init.luau, 002_*.luau …
├─ tests/               ← Lune specs (run without Studio)
└─ README.md            ← config keys with defaults, API, hooks, save data shape
```

Rojo mapping (`tools/make-module` and the generators produce this):

| Part | Goes to |
|---|---|
| `module.luau` | `ReplicatedStorage.Modules.<Name>.module` |
| `client/` (incl. the generated `client/Net.luau`) | `ReplicatedStorage.Modules.<Name>.client` |
| `shared/` | `ReplicatedStorage.Modules.<Name>.shared` |
| `migrations/` | `ReplicatedStorage.Modules.<Name>.migrations` |
| `server/` (incl. the generated `server/Net.luau`) | `ServerScriptService.Modules.<Name>` |

The loader finds a module's server and client parts **by name** in those folders (§19.9). Since
v1.3.1 the built-in kits use exactly this layout (`packages/kits/<kit>/<Module>/`); the
`Modules` entries of every project in the repo are generated by `tools/sync-projects`.

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
local Modules = ReplicatedStorage:WaitForChild("Modules") -- one folder per module (§1, §19.9)
return {
	gameId = "example-shop",
	modules = { require(Modules.Items.module), require(Modules.Inventory.module),
	            require(Modules.Economy.module), require(Modules.ClueGenerator.module) },
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

If any step throws, boot **fails closed**: every later call errors with the boot message, as in v1.2.

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
local Economy = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))
local economy = StudWork.use(Economy)        -- typed as Economy's API (server) / ClientAPI (client)
economy.grant(player, 10, "quest")
```

- `StudWork.use(ref)` returns the module's **frozen** public API for the current side.
- If the module isn't enabled, `use` returns an erroring proxy that says "Economy is not enabled in GameConfig.modules". It doesn't return nil.
- Calling `use` before `StudWork.start` errors.
- **Inside a module, use `ctx.deps`, not `StudWork.use`.** `ctx.deps` contains exactly the declared dependencies, so an undeclared dependency is a boot error and not a hidden coupling. A lint rule enforces this.
- `StudWork.Economy`-style sugar is generated for **every** enabled module, built-ins and third-party alike. It's untyped, a convenience for the command bar and console. Typed code uses `StudWork.use`.
- **`StudWork.use` only accepts a `ModuleRef`.** (**Why:** the v1.2
  `Modules.API.Data` includes `get`/`update`/`getGame`/`updateGame` on the *whole* `PlayerData`,
  which a public `StudWork.use(Data)` would hand to any module or game script, defeating "a module
  can read and write only its own save section" (§4 above, philosophy §4). **Data, Compliance,
  Net, Replication, Shop and Policy are framework internals, not modules: they have no
  `ModuleRef`, no public facade, and are not reachable through `StudWork.use` at all.** Their only
  surface is what `ctx` exposes to a module (`ctx.data`, `ctx.compliance`, `ctx.net`,
  `ctx.replicate`, `ctx.shop`, `ctx.policy` — §5), each already scoped to the calling module. The
  one exception is `StudWork.use(Shop).onProduct` in §7's example, which is wrong as written and
  is corrected there.)

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
	framework: FrameworkRead,            -- read-only: firstJoin(player), lastSeen(player) (§5.2)

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

- **`tx` is a sealed handle, not a table with a `data` field.** (**Why:** v1.2's `Tx` type has `data: PlayerData` as a real field (`server/Context.luau:32-36`); if
  that survived into v1.3, `tx.data.otherModulesSection` reaches every section directly and
  defeats §5.1's guarantee. The framework holds each tx's working copy in a private table keyed
  by the tx handle itself (an opaque frozen marker table with no fields), never on the handle.
  `tx.player`, `tx.after` and `tx.retryLater` stay as they are (they carry no section data); there
  is no `tx.data`. A test asserts that indexing, iterating or `rawget`-ing a `tx` for anything but
  `player`/`after`/`retryLater` returns nil or errors.)
- **Only one tx per player may be open on the call stack at a time, and it is single-player.**
  (**Why:** while a module's code is running inside `ctx.tx(player,
  fn)`, calling any OTHER module's mutating public API for a DIFFERENT player (which would need
  its own `Data.update`/`ctx.tx`) errors immediately: "tx open for `<player>`; use `tx.after` to
  act on another player once this one commits." This is the same non-nesting rule v1.1's
  `Data.update` already enforces for the *same* player, generalised to
  the transaction object. Cross-player effects (a gift's receiver, a friend's co-play bonus) go
  through `tx.after` once the opener's commit lands, or through Mail (§ Compliance/Mail stays
  async for exactly this reason).)

---

## 5.2 Read-only framework facts

`ctx.framework` gives every module the handful of `_framework`-section facts that today's
`PlayerData` exposes directly (`firstJoin`, `lastSeen`), without handing out the whole section:

```lua
type FrameworkRead = {
	firstJoin: (player: Player) -> number,  -- unix seconds
	lastSeen: (player: Player) -> number,   -- unix seconds, updated on leave and periodically
}
```

Offline and Streak use this instead of reaching into `_framework` directly (there is no API that
lets them; §6 below).

---

## 6. Save data: a section per module

```
Profile.Data = {
	_framework = { schemaVersion = 2, firstJoin = …, lastSeen = …, purchases = {…}, funnel = {…} },
	_versions  = { economy = 1, collection = 3, quests = 1 },
	economy    = { … },       -- owned by Economy
	collection = { … },       -- owned by Collection
	quests     = { … },       -- owned by a third-party module
	["example-shop"] = { … }, -- the game's own section (today's PlayerData.game[gameId])
}
```

- **Each module migrates its own section** with its migrations folder. This generalises today's game-table `_version` pattern.
- **If any migration fails, nothing is saved** and the player gets the friendly kick, with the same guarantee as v1.1.
- **The framework's `_framework` section** (purchases, funnel, first and last seen) has its own migrations.
- **Sections of modules that aren't enabled are kept untouched.** Switching a module off must never delete data. A disabled module's section is carried through saves as-is.
- **`ScopedData` API:** `get(player)` returns a frozen read-only view of the module's own section. `update(player, fn(section))` is shorthand for `ctx.tx` touching only this section. `isLoaded(player)`, `onLoaded(fn)`.
- **Per-section versions for Replication** are kept as v1.2's `sectionVersion`, now keyed by module.
- **The game's own section** is simply the game acting as a module: `games/<g>` gets an implicit module named after `gameId`, with `config.data` as today. That's not special either.
- **Moving v1.2 saves:** a `_framework` migration splits a v1.2 flat save into sections. There are no published games yet, but write it anyway and test it. It proves the migration path works.
- **Frozen read views apply everywhere, not only in Studio.** (**Why:** v1.2's
  `Data/ReadOnlyView.luau` only wraps `Data.get`/`getGame` in Studio;
  on live servers, and for every other module's `get`/`list`-style read (`Inventory.get` is a
  concrete v1.2 example that returns the live `ItemInstance`), callers get a live reference and
  an in-place write silently skips migrations and replication. `ScopedData.get` and every value a
  module's API returns from its own section are frozen (or a fresh copy for non-table values) in
  every environment, reusing the per-section-version cache so this isn't a copy on every read.
  This is one of the things to re-check against the §17 question 6 performance budget.)
- **Each disabled module's section records its owner, and a key collision is a boot error.**
  (**Why:** §2 only checks that `data.key` is unique *among enabled
  modules*; a new, unrelated module reusing a disabled module's old key would silently inherit
  data in a shape it never wrote. `_framework._owners: { [key]: moduleName }` is written the
  first time a module's section is created and checked every boot: a key whose recorded owner
  doesn't match the module now claiming it is a boot error, unless that module's definition
  declares `data.adopts = "<oldModuleName>"`, which is itself logged in `decisions.md`-style
  fashion inside the module's own migration.)
- **Each module may declare `data.sanitize = fn(section) -> section`,** run once after migrations
  on load, before the section is used. (**Why:** v1.2's
  `Data/Sanitize.luau` has no per-module equivalent in the draft; giving every module the same
  hook it already effectively needs generalises it instead of leaving it framework-only.)

---

## 7. Purchases (Shop) for modules

The guardrail stays entirely inside the framework; `onProduct` is registered with `ctx.shop`, not
`StudWork.use(Shop)` (Shop is a framework internal, not a `ModuleRef`; see §4):

```lua
-- any module's server/init.luau, including the game's own implicit module (see below)
function M.init(ctx)
	ctx.shop.onProduct("CoinPack1000", function(tx: PurchaseTx)
		tx.use(Economy).grant(1000)                 -- Economy's purchaseOps.grant
		tx.use(Collection).addItem("GoldenPebble")   -- source auto "paid:<product>" (§14)
	end)
end
```

- A module declares `server.purchaseOps`: functions with the shape `(tx, ...)` that are safe inside a receipt transaction. `tx.use(ref)` exposes them, typed.
- The Shop wrapper keeps the v1.1 contract:
  - one non-yielding `Data.update`,
  - the receipt is recorded in `_framework.purchases` in the same commit,
  - `PurchaseGranted` only after the save,
  - `tx.retryLater`, `tx.after`.
- `tx.paid = true` and `tx.paidRandomRestricted` are set by the framework and can't be changed.
- Random purchase ops must go through `ctx.compliance` (§14), and `ctx.compliance.roll`/`spendForRoll` are the only way to produce a random outcome inside a paid transaction (§14).
- **A game's gameplay code is its own implicit module, not a free-standing script.**
  (**Why:** v1.2 purchase handlers get the whole `data` table
  (`Types.luau:564`) and games call `Core.Data.updateGame` straight from
  `games/<g>/src/server/Main.server.luau`, neither of which exists in v1.3: handlers only get `tx` (§5.1), and there is no public
  whole-profile Data access to call from a plain script. §6 already says "the game acting as a
  module"; this makes it literal. `games/<g>/src/server/Main.server.luau` is retired. In its
  place, `games/<g>/modules/<gameId>/` is a module shaped exactly like a kit module (§1):
  `module.luau` declares it (`dependsOn`/`optional` on whichever kits the game uses),
  `server/init.luau` gets a real `ctx` with `ctx.data`, `ctx.tx`, `ctx.section`, `ctx.shop`, and
  it is auto-added to `GameConfig.modules` (the game doesn't list itself). Its purchase handlers,
  product registrations and game-specific logic live there with the same guarantees as any other
  module — "nothing in core is special" applies to the game's own code too.)

---

## 7.1 The framework owns `ProcessReceipt` exclusively

(**Why:** v1.2 assigns `MarketplaceService.ProcessReceipt` in
`Shop.start` (`Shop/init.luau:302`) with nothing stopping a module or game script from
reassigning it afterwards; Roblox allows only one `ProcessReceipt` function at a time, so
whichever assignment runs last silently wins and every purchase-safety guarantee in this document
stops applying.)

- **Shop claims `ProcessReceipt` in the last framework-init boot step** (§3 step 3), after every
  module's `init` has run, so no module `init` can race it.
- **A lint rule bans any other assignment to `MarketplaceService.ProcessReceipt`,**
  `MarketplaceService.PromptGamePassPurchaseFinished`/`PromptProductPurchaseFinished` callbacks
  outside the framework, and direct `DataStoreService`/`ProfileStore` use outside `server/Data`,
  the same way the existing guardrail bans raw `RemoteEvent`/`OnServerEvent` (§9).
- **Shop also detects a replacement at runtime, not just at lint time:** on a short heartbeat-driven
  interval it checks `MarketplaceService.ProcessReceipt == <the function Shop assigned>`. A
  mismatch is a loud `warn` naming the offending source when it's detectable (the function's
  debug info — script path — via `debug.info`, falling back to "unknown source" when Luau can't
  resolve it) **and** an analytics event (`ProcessReceiptHijacked`, with that source string), so
  the conflict is visible in logs and in Analytics rather than fought silently; Shop then
  immediately reassigns itself. This is defense in depth under "guardrails stay on" (philosophy
  §4): the lint rule stops it at review time, the runtime check catches what the lint rule can't
  see (dynamically generated assignments, a vendored package with its own `ProcessReceipt`), and
  the warning + analytics event mean a real conflict shows up instead of becoming an invisible
  fight over who grants purchases.

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
- **Inverted extensions solve the v1.2 reverse-dependency cases.** (**Why:** several v1.2 writes cross module lines against the natural dependency direction:
  `Inventory.transfer` clears a slot in Plot's section (`Inventory/init.luau:381`) even though
  Plot depends on Inventory, not the other way around; a claimed gift adds to the inventory from
  inside Mail's claim handler, a two-way coupling. The fix is the *same* extension mechanism,
  just offered by the module being acted on rather than the one acting:

```lua
-- Collection (owns item removal) offers an extension FOR its dependents:
extensions = {
	onItemRemoved = function(fn: (tx: Tx, player: Player, instance: ItemInstance) -> ()) … end,
}
-- Base's Plot, which declares optional = { Collection }, hooks its OWN cleanup:
if ctx.isEnabled(Collection) then
	ctx.depsExt[Collection].onItemRemoved(function(tx, player, instance)
		local mine = ctx.section(tx)   -- Plot's OWN section; ctx here is Plot's, closed over at registration
		for slotId, uid in mine.displayed do
			if uid == instance.uid then mine.displayed[slotId] = nil end
		end
	end)
end
```

  The hook fires inside the *triggering* module's transaction (Collection's, when an item is
  removed), but because `ctx.section(tx)` is bound to whichever module's `ctx` registered the
  hook (Plot's), the hook writes only Plot's own section — the same `ctx.tx`-spanning-multiple-
  sections mechanism §5.1 already uses for `ctx.depsTx[Economy].grant(tx, ...)` plus
  `ctx.section(tx)` for the caller's own section, just entered from the other side. This needs no
  new runtime concept, only the documented pattern and an example. Social's Mail gets the same
  treatment: it offers `extensions.registerKind(kind, claimFn(tx, player, payload) -> boolean)`,
  so Collection (or a third-party module) can own what happens when ITS kind of mail is claimed,
  without Mail depending on Collection to interpret the payload. §16's mapping table lists where
  each kit uses this.)

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
- On the client, `StudWork.use(Upgrades).actions.upgrade(id)` comes from the module's client part (`actions = { "upgrade" }` fires the module's own `Net` event of that name or its PascalCase name, §19.9). Calling an action of a module that isn't enabled gives the clear error. Since v1.3.1 the framework client has no module actions of its own (only `triggerEvent` and `funnel`).
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

- **`data`:** the fields listed in `data.replicate`, minus `serverOnly`. These are diffed by section version, as in v1.2.
- **`extra`:** set with `ctx.replicate.set(player, key, value)` and `setAll(key, value)`, namespaced to the module automatically. `ctx.replicate.sent(player, key)` stays available, for the luck-disclosure check.
- **Client selectors:** `StudWork.use(Economy).state()` returns that module's slice as a Charm atom selector. UI code never digs through `modules.X` by hand.
- **`data.replicate = true` (whole-section) is not a real option; it's a documentation bug in the
  original draft.** (**Why:** §2's own example writes
  `replicate = { "currency" }`, but prose elsewhere and §18's example used `replicate = true`,
  which would send a module's entire section, including fields nobody intended to expose (pity
  counters, outbox contents, internal counters). `data.replicate` is always an explicit list of
  field names, or `false`/omitted for "nothing replicates." §18's example is corrected to match.)

---

## 11. Config

- **Each module's config lives under `GameConfig.config.<Name>`.** It's merged over the module's `defaults` and validated against its `schema`. Unknown keys produce a warning, so typos get caught.
- **The schema language** stays the small type-string format that ConfigValidate already handles, extended where needed: optional `?`, lists, maps, enums, number ranges. Every key carries a description and a default, so the module's README can be generated from it.
- **Framework-level config stays at the top level:** `gameId`, `modules`, `items`, `products`, `events`, `theme`, `client`, `data` (the game's own section).
- **`ServerConfig.<Name>`** is server-only config, for admin IDs and the like. It's never replicated.

---

## 12. Items and item fields

**Base `ItemDef`** (in the framework, so items exist even without any kit; §17 question 1:
framework, not Collection):

```lua
{ id: string, name: string, rarity: string?, model: string?, icon: string?, tags: {string}?,
  source: string?, keepOnRebirth: boolean?, [namespace: string]: { … } }
```

- `rarity` is a **string** validated against the active tier list (§13). It's not a fixed union type any more.
- Modules add namespaced fields: Economy adds `item.economy.incomePerSec` and `mutation.economy.incomeMultiplier`. The validator rejects namespaces that no enabled module declared.
- A collection-only game: items without an `economy` table earn nothing, and that's valid.
- **Items exist only through `GameConfig.items`, validated once at boot. Registering an item after
  `StudWork.start` is a hard boot-time-style error, not a silent no-op or a deferred feature.**
  (**Why:** v1.2's `Items.register` can be called any time, with `Items.onRegistered` re-sending
  odds for the new items; v1.3 drops that path on purpose, because a late-registered item
  could enter a paid random table before Compliance has disclosed its odds to anyone — exactly
  the hole the paid-random guardrail exists to close. There is no `register` function on any
  item-related API in v1.3: an attempt to add an item outside `GameConfig.items` (a module calling
  something that doesn't exist, or a stray `Items`-shaped call left over from a v1.2 port) errors
  immediately with "items must be declared in GameConfig.items; registering items after start is
  not supported …" rather than failing quietly or partially working. This is listed under Breaking
  in the v1.3.0 entry of [the framework changelog](../../packages/framework/CHANGELOG.md). Full post-boot
  registration, with Compliance re-disclosing odds before the item can be rolled, is explicitly
  left for a later version, not attempted here.)

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
ctx.compliance.registerRandomSource(id, {
	odds = fn(player) -> OddsDetail,
	sample = fn(player, luck) -> SampleResult,  -- picks ONE outcome; this is the actual randomness
	luckDisclosed = boolean,
})
-- The only way to produce a random outcome from a registered source, free or paid:
ctx.compliance.roll(tx, sourceId, luck?) -> (ok: boolean, outcome: SampleResult?, reason: string?)
-- Paid-currency-priced rolls: spends the currency AND rolls atomically.
ctx.compliance.spendForRoll(tx, currency, amount, sourceId, luck?) -> (ok, outcome?, reason?)
ctx.compliance.tagPaid(source) -- "paid:<id>" / "paidcur:<id>", applied automatically (see below)
```

- Collection's Rarity registers its tables this way, and so must any third-party random source.
- The framework replicates the disclosed odds and provides the `OddsTable` screen for any registered source.
- **`ctx.compliance.roll` performs the sample itself; it is not a separate check next to the
  module's own randomness.** (**Why:** the original
  `checkPaidRoll(tx, sourceId, luck)` only recorded that *some* check ran; a module could call it
  with a harmless `sourceId`/`luck` and then roll its own weights however it liked, so the
  disclosed odds never had to match what was actually granted. There is no module-side sampling
  path for a compliance-covered source: `registerRandomSource` takes a `sample` function (the
  weighted pick, pity included), and `ctx.compliance.roll`/`spendForRoll` are what every caller —
  built-in or third-party — must use to get an outcome. The policy check, the luck-disclosure
  rule and the sample happen in one call that the framework controls end to end.)
- **Paid currencies are declared once, at the framework level, and can only be spent for a roll
  through Compliance.** (**Why:** v1.2's `paidCurrencies` lives in
  `BalanceConfig`/Economy's config (`Rarity/init.luau:111`), so a third-party currency module that
  never opts in is invisible to the rule, and v1.2 already lets `Economy.spend` and `Rarity.roll`
  run as two separate transactions (`Rarity/init.luau:227-236`), so nothing ties the spend to the
  roll it paid for. In v1.3: `GameConfig.compliance.paidCurrencies: { string }` is top-level
  framework config, read by Compliance directly, not routed through Economy. Economy's own
  `txApi.spend` refuses to spend a currency on that list (errors "spend a paid currency only
  through compliance.spendForRoll"); the *only* path to spend one is
  `ctx.compliance.spendForRoll(tx, currency, amount, sourceId, luck?)`, which spends (via
  Economy's `txApi`, which Compliance is allowed to call) and rolls in the same transaction, so
  the two can never be split across commits.)
- **There is no `opts.free` escape.** (**Why:** this is the stricter of the two options: v1.2's `RollOptions.free` (`Types.luau:79-81`) lets any caller declare a
  roll on a paid-currency table "free", which bypasses the whole rule by assertion. v1.3 drops
  it: a genuinely free reward (a streak bonus, a quest payout) calls `ctx.compliance.roll(tx,
  sourceId, luck?)` directly — no currency changes hands, so there is nothing to misclassify — and
  a currency on `compliance.paidCurrencies` is *always* paid when spent. If a game needs a
  currency that's sometimes sold for Robux and sometimes handed out free, that's two different
  currencies in its config, which is also more honest to players.)
- **A restricted or policy-unknown player is handled inside `roll`/`spendForRoll`, not by every
  caller.** (**Why:** v1.2 handlers each call `Policy.isKnown` and
  `tx.retryLater()` by hand in every purchase handler.
  `ctx.compliance.roll`/`spendForRoll` check `ctx.policy` first: unknown → `tx.retryLater()`
  automatically inside a purchase transaction (or `(false, nil, "policy_unknown")` outside one);
  known-restricted → `(false, nil, "restricted")`. Callers grant a fixed non-random fallback on
  `"restricted"`, same as today, but don't have to special-case `"policy_unknown"` themselves.)
- **A granted item's `paid:`/`paidcur:` tag is derived, not passed in.** (**Why:** v1.2's `Inventory.add`/`addInto` accept any `source` string, and only Shop's
  own call sites remember to prefix it (`Shop/init.luau:154-155`); a module calling
  `tx.use(Collection).addItem` directly could omit the tag and make a Robux-bought or paid-roll
  item look untradeable-safe or rebirth-wipeable when it shouldn't be. Collection's `addInto`
  derives the prefix itself from the transaction (`tx.paid` for a Shop transaction,
  `"paidcur:<sourceId>"` when the copy came from `compliance.roll`/`spendForRoll`) and a caller's
  `source` becomes the free-form reason suffix, never the prefix.)
- **What is enforced:**
  - Shop marks every purchase transaction as paid.
  - The only way to get a random outcome from a registered source is `compliance.roll` /
    `spendForRoll`, so there is no "didn't call the check" bypass left to detect.
  - Spending a `compliance.paidCurrencies` currency is only possible through `spendForRoll`.
- **What can only be guided:** arbitrary module code could still invent randomness outside these APIs (raw `math.random`/`Random.new`, never registering a source at all). The documentation, the generator template and a lint heuristic (`math.random`/`Random.new` in a function that also calls `Economy`'s grant/spend or touches an item) steer authors to Compliance. Say this honestly in the guardrails documentation.

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

- These are the v1.2 multi-player test helpers, promoted to public API.
- A whole-game sim (`Fixtures.gameServer`, the generated `module.spec.luau`): call an action with
  `server:action(player, module, name, ...) -> (ok, result | reason)`; the server's prints and
  warnings are in `server.output`. A test that never completes fails after `STUDWORK_TEST_TIMEOUT`
  seconds (default 60) instead of ending the run silently (v1.6.0).
- Every module generated by `tools/make-module` comes with a passing harness test.

---

## 16. How today's code maps to the kits

| Kit | Modules | Notes |
|---|---|---|
| **framework** | Data, Net, Replication, Shop + Tx, Policy, Compliance, Events, Analytics, Console, Theme, Input, Feedback, UI runtime (screens, HUD slots) | Always on. `Core.Net` (GameNet) becomes module and game actions |
| **collection** | Items, Inventory (cap, transfer, gift), Rarity (tiers, pity, mutations, luck) | Contributes `theme.rarity`, the Odds and Inventory screens, and purchase ops `addItem` and `roll` |
| **economy** | Economy, Upgrades, Rebirth, Offline | Adds the item and mutation fields, the currency and rate widgets, the purchase op `grant`, and the extension `Rebirth.resetStep` |
| **base** | Plot | Optional dependency on Economy (reset step) and on Collection (`onItemRemoved` inverted extension, §8, clears the slot when an item leaves instead of Inventory writing into Plot's section directly). Plot model and tag set in config |
| **social** | Friends, Mail (mailbox, outbox, gifting via Collection's transfer) | Offers `registerKind` (§8) so Collection (and third-party modules) own what a claimed mail kind does, instead of Mail depending on Collection. Contributes the mailbox widget and screen |
| **engagement** | Streak | Time zone and grace window in config |

Whether a kit is one module or several (`Kits.Economy` as one module versus `Economy`, `Upgrades`,
`Rebirth` and `Offline` as four) is settled by §17 question 2: finer modules, plus bundles.

---

## 17. Design questions and answers

Questions raised while the design was written, with the answers the implementation follows.

1. **Should `ItemDef` belong to the framework or the Collection kit?** Framework. (Keeping `{id, name, rarity, model, icon, tags, source, keepOnRebirth}` item-agnostic in
   the framework lets non-Collection kits (Base's Plot slot display, Social's gift payloads)
   reference an item id without pulling in Collection as a hard dependency. Collection still owns
   the rarity *tier list* and validates the `rarity` string against it (§13); it just doesn't own
   the shape.)
2. **How fine-grained should modules be inside a kit?** Finer modules (today's 11: Items,
   Inventory, Rarity, Economy, Upgrades, Rebirth, Offline, Plot, Friends, Mail, Streak), each a
   real `defineModule`, plus a `Kits.<Name>` bundle ref per kit that expands to its modules in
   dependency order. (Finer modules preserve v1.2's existing hard
   dependency graph in `Modules.SPECS` exactly, which the existing tests already cover; one module
   per kit would force Inventory/Rarity/Upgrades/Rebirth/Offline to share one data section and one
   migrations folder, which is a bigger behavior change than this round allows.)
3. **Blink per module:** workable. (`tools/net` already compiles one
   `core.blink` into three generated files per side; extending it to loop over every module's
   `net.blink` and emit `Modules/<Name>/{server,client}/Net/Generated.luau` is the same codegen
   repeated per file, so build time scales linearly with module count, not quadratically. The Rojo
   mapping already supports one project file per module folder (`server/`, `client/`) per §1.)
4. **Typing `StudWork.use`:** needs a generic signature, no fallback accessor needed. (Luau's generic resolution through a table-returning function like
   `defineModule(...) :: ModuleRef<API, ...>` does carry the cast type to the call site under
   luau-lsp strict mode, confirmed against how `Context.luau`'s `*Internal` intersections already
   type-check today. `StudWork.use(ref)` needs a generic function signature
   `use<A, T, C>(ref: ModuleRef<A, T, C>): A` — straightforward in Luau. Each module's definition
   file already carries the `:: StudWork.ModuleRef<...>` cast per §2, so `StudWork.use` just
   forwards that type.)
5. **The compliance check at commit:** implementable. (Give `Tx` an internal,
   non-module-visible flag set only by `ctx.compliance.checkPaidRoll` and read only by Shop's
   commit path — the same pattern `EconomyInternal.grantInto` already uses to queue `tx.after`
   work invisibly to the calling module. No module can see or clear the flag, so it can't be
   spoofed from module code; only Compliance and Shop touch it. §14 later replaced the separate
   check with `ctx.compliance.roll` doing the sample itself.)
6. **Performance:** target kept — flag any regression over 20% against the v1.2 bench
   (0.64 ms/tick at 50 players × 100 items), measured with `tools/bench`.
7. **The v1.2 save migration:** covered. (Each field has a clear new
   home — `displayed`→Base's `plot` section, `upgrades`→Economy's `economy` section,
   `pity`→Collection's `collection` section, `mail.outbox`/`mail.box`→Social's `social` section,
   `stats`/`funnel`/`purchases`/`firstJoin`/`lastSeen`→`_framework`, `game`→the game's own implicit
   module section. The `_framework` migration is tested against a v1.2 save fixture, since there
   was no published game to migrate for real.)

---

## 18. Sketch: a third-party module (`examples/modules/session-leaderboard`)

```lua
-- module.luau
return StudWork.defineModule({
	name = "SessionLeaderboard", version = "0.1.0", framework = "^1.3.0",
	dependsOn = {}, optional = { Economy },
	config = { schema = { stat = "string", top = "number" }, defaults = { stat = "earned", top = 10 } },
	-- replicate lists the fields the owning client sees; there is no whole-section `true` (§10)
	data = { key = "sessionLeaderboard", version = 1, default = { best = 0 }, replicate = { "best" } },
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

## 19. Additions after the design freeze (v1.3.0, v1.3.1)

Additive surfaces added after §0–§18 were frozen. Nothing above changed.

### 19.1 `ctx.data.shared`: the cross-server shared store (added in v1.3.0: Mail's gift cap and return-to-sender need one atomic record per recipient that every server can update)

```lua
local ok, new = ctx.data.shared.update(key, function(old) return new end)
```

- One durable store shared by every server of the experience: a framework-owned DataStore
  (`StudWorkShared_<gameId>`, `_Studio` suffix in Studio) behind `UpdateAsync`, so the
  read-modify-write is atomic across servers.
- Keys are the module's own. The framework prefixes every key with `<ModuleName>/`, so a module
  can't read or write another module's keys. The full key, prefix included, is at most 50
  characters (the DataStore key limit).
- `fn(old)` returns the new value. Returning `nil` deletes the key. `fn` can run more than once
  (UpdateAsync retries on a conflict), so it must only compute from `old`.
- `update` yields. Call it from a thread, never in the body of `init` or `start`. A failing call
  is retried with backoff. The final failure returns `(false, nil)` and logs a warning. An error
  inside `fn` writes nothing and isn't retried.
- In Studio without API access, the store falls back to an in-memory one with a warning, like
  Data does. The test harness uses an in-memory store. In the multi-server sim, every sim server
  shares the World's mock DataStore, which also supports failure injection.
- The store is durable and has no expiry. A MemoryStore fast path wasn't added because the gift
  escrow needs durability and nothing else needed one (see [decisions.md](../decisions.md)).
- `DataStoreService` and `MemoryStoreService` stay framework-only (guardrails `purchases` check).

### 19.2 `ctx.now()`: the framework clock (added in v1.3.0: time-based modules and their tests need the clock that stamps `lastSeen`, not `os.time()`)

`ctx.now() -> number` returns unix seconds from the runtime's clock. That's `os.time()` live,
the harness clock in `harness.luau` (`h:tick`, `h:rejoin({ secondsAway })`), and the World clock
in the sim. It's the same clock as `ctx.framework.lastSeen`. Kit code uses it instead of
`os.time()` (Offline, Streak, Mail gift expiry, Economy boost expiry, Inventory `acquiredAt`).

### 19.3 `theme = function(config) -> table` (added in v1.3.0: Rarity's tiers come from `config.Rarity.tiers`, so games stop repeating them in `GameConfig.theme`)

A definition's `theme` (§13) can also be a function. It receives the module's merged and
validated config, on the server and the client (both merge through the shared `ConfigValidate`).
It returns the same token-group table a static `theme` would. The merge order is unchanged:
preset → each enabled module's contribution in boot order → `GameConfig.theme`. A function
that errors, or returns something other than a table, is a boot error. Rarity contributes
`theme.rarity.tiers` from `config.Rarity.tiers`.

### 19.4 HUD widgets: `UI.registerWidget` (added in v1.3.0: §13 says modules contribute widgets but named no call)

`UI.registerWidget(id, spec | false)` (`packages/ui`) is the one documented call. `id` is
`"<Module>.<widget>"` and `spec = { slot, order?, component }`. `false` removes the widget.
`StudWork.Client.Hud.addWidget` is the same function, also listed in `Types.HudAPI`. Call it from
a module's client `start` or from a game's client script. Games hide a widget with
`GameConfig.client.hud = { widgets = { [id] = false } }`.

### 19.5 `StudWork.test` in full (added in v1.3.0: §15 sketched the harness; real specs needed shared stores, failure injection and several servers)

`StudWork.test` is Lune-only: the test kit serves it (`packages/framework/test/Public.luau`), and
it's never in a game build (outside Lune it errors).

- `StudWork.test.harness(opts)`: the §15 harness. Every module's server part is found the way a live
  game finds it, so kit modules run for real. `opts.servers = { Name = part }` injects a part (a
  test double, or the module under test), which wins over the live lookup. The other options are
  the GameConfig keys (`config`, `items`, `products`, `events`, `compliance`, `gameId`, `theme`,
  `analytics`) plus `serverConfig`, `store`, `startTime`, `isStudio`, `policy` and `owned`.
- `h:purchase(p, product, { retries?, redeliver?, purchaseId?, price? }) -> (decision, all)` builds the
  receipt for a devProduct name or id. It re-delivers while the answer is `NotProcessedYet`, up to
  `retries` times, or every time when `redeliver` is set.
- `StudWork.test.boot(opts) -> (h?, err?)` returns a boot error instead of raising it.
- `StudWork.test.memoryStore()` is one in-memory store that several harnesses can share (one
  "DataStore" for several servers). `store.failNext(n)` makes the next `n` loads or saves raise.
- `StudWork.test.player(userId, name?)` is a bare mock player.
- `StudWork.test.sim.*` is the multi-server simulation: real ProfileStore session locks on a mock
  DataStore and MessagingService, latency, crashes, server close (BindToClose) and failure
  injection (`world:failNext` / `failFor`).
  - `sim.world({ epoch? })`, `sim.server(world, opts)`, `sim.gameServer(world, projectPath)`,
    `sim.bootGame(projectPath)` and `sim.buyItem(world, server, player, product, itemId)`.
  - A server offers `server:join` / `leave` / `purchase` / `crash` and server close.
  - It also offers `server:use(Ref | name)`, `server:ref(name)`, `server:section(p, key)`,
    `server:sections(p)` and `server:update(p, fn(sections, tx))`.
  - Further: `server:save(p)`, `server:onProduct(product, fn(tx))`, and `server:heard("<Module>.<Signal>"
    | "framework.<Signal>")`, which records every firing since boot.
  - Stored sectioned saves: `sim.saved(world, userId)` and `sim.section(world, userId, key)`.

### 19.6 `ctx.compliance.spendPaid` (added in v1.3.0)

```lua
ctx.compliance.spendPaid(tx, currency, amount, reason) -> (ok, reason?)
```

- Spends a `compliance.paidCurrencies` currency on a **non-random** good (an upgrade level, a
  rebirth, a hat in any module's shop) through the currency's registered spender, inside the
  caller's tx. Any module can call it; the economy kit's Upgrades and Rebirth use it (the kit's
  kits hold no private access token).
- `currency` must be a paid currency (else it errors; spend free currencies through their own
  module), `amount` a finite number > 0, `reason` a non-empty string (the spender's sink reason).
  Not enough funds: `(false, "insufficient")`, nothing spent.
- It marks the tx: a `ctx.compliance.roll` later in the same tx is a **paid** roll (policy,
  odds disclosure and the luck rule apply; a refused roll returns its reason, so error to discard
  the spend), tagged `"paidcur:<sourceId>"`. Before such a roll `tagPaid(tx)` returns
  `"paidcur:<currency>"`.
- `Economy.spend` / `txApi.spend` still refuse paid currencies (§14, same error text).
- The spender registered with `registerCurrencySpender(currency, fn(tx, amount, reason?))` now gets
  the reason as a third argument (`"roll"` for `spendForRoll`).

### 19.7 Paid rolls need disclosed odds; tags can't be forged (added in v1.3.0)

- A paid roll (inside a purchase, through `spendForRoll`, or after `spendPaid`) on a source whose
  odds this player's client was never sent (`ctx.compliance.disclosed(player, sourceId) == nil`) is
  refused at any luck: inside a purchase `tx.retryLater("odds_not_disclosed")` (Roblox retries; no
  grant, no record), otherwise `(false, nil, "odds_not_disclosed")`. Odds are sent when the
  player's client subscribes after join, before it can buy.
- `tagPaid(tx, reason)` outside a paid tx strips a caller's `"paid:"` / `"paidcur:"` prefix
  (`"paid:CoinPack"` -> `"CoinPack"`; nothing left -> `"free"`).

### 19.8 Committed data is frozen; migration gaps; theme typos (added in v1.3.0)

- **Never keep a `ctx.section(tx)` reference past the tx.** Committed section tables are frozen:
  a write through a kept reference after the tx raises `attempt to modify a readonly table` and
  changes nothing.
- A gap in a module's migration numbers, between its first migration and `data.version`, is a
  boot error naming the missing number.
- An unknown key in `GameConfig.theme` (or a preset table) under `colors`, `fonts` or `metrics`,
  or an unknown group, is a boot warning naming it. A bare component in
  `client.hud.widgets[id]` replaces that widget's component and keeps its slot, order and module.

### 19.9 One folder per module: the live part lookups (added in v1.3.1)

Every module, the built-in kits included, ships as one folder (§1) and is mapped by Rojo as
`ReplicatedStorage.Modules.<Name>.{module, client, shared, migrations}` and
`ServerScriptService.Modules.<Name>` (the server part). There is no other place: the pre-v1.3.1
`ReplicatedStorage.Kits` / `ServerScriptService.Kits` folders, the kits' `ModuleServers.luau` /
`ModuleClients.luau` and the one-level-down `ServerScriptService.Modules.<Folder>.<Name>` scan are
gone. Code reaches a module's definition (its ModuleRef) by name:

```lua
local Economy = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))
```

A module's own client part reaches its definition as `script.Parent:WaitForChild("module")`; its
server part lives in ServerScriptService, so it uses the `ReplicatedStorage.Modules.<Name>.module`
path above.

**Server part** (framework `Loader.defaultLoadServer(ref)`):
- `ServerScriptService.Modules[ref.server]`, a direct child, nothing else. None = a
  definition-only module (valid).
- If the required table has a `new` function and no `init` / `start`, it is a part **factory**:
  the loader calls `new()` and uses the result, so two runtimes in one process (tests, the
  multi-server sim) never share module state.
- If the part has no `net` field and the server part instance has a `Net` ModuleScript child
  (the module's generated Blink server module, `server/Net.luau`), that module becomes the part's
  `net`: it backs `actions` (§9).

**Client part** (framework `Runtime.defaultLoadClient(ref)`):
- `ReplicatedStorage.Modules[ref.client].client` (the game's own module:
  `ReplicatedStorage.GameModule.client` first).
- The part's `net` defaults to that instance's `Net` child (`client/Net.luau`) the same way, so
  `actions = { "upgrade" }` fires the module's own `Upgrade` / `upgrade` event.

Both conventions apply to every module (kits and third-party alike). Tests reach the same lookups:
the Lune testkit and the multi-server sim map `ReplicatedStorage.Modules` /
`ServerScriptService.Modules` from the module folders exactly like Rojo
(`tools/lune/ModuleDiscovery.luau`), and `StudWork.test.harness` loads every listed module's server
part through `Loader.defaultLoadServer` unless `servers = { Name = part }` injects one. Lune has no
Blink wire: drive actions with `h:action(p, Ref, "name", ...)`, and never require a generated
`Net.luau` at module load in code Lune runs (the testkit and the sim call
`Loader.defaultLoadServer(ref, nil, { bindNet = false })`, so a module's `Net` child is not bound
there).

HUD widgets of the kits moved with this change: `"Economy.currency"` is registered by the Economy
client part and `"Social.mailbox"` (plus `StudWork.use(Mail).onMailbox`, the mailbox screen and its
claim) by the Mail client part, both with `UI.registerWidget` under the same ids, so
`client.hud.widgets[id] = false`, replacement specs and custom layouts work as before; a widget
registered after the HUD mounted renders at once.

### 19.10 Every paid currency has a spender at boot (added in v1.3.1)

`GameConfig.compliance.paidCurrencies` lists the currencies bought with Robux; §19.6 says they are
spent only through `ctx.compliance.spendForRoll` / `spendPaid`, which call the spender the
currency's owner registered with `ctx.compliance.registerCurrencySpender(currency, fn)`. Boot step
5 (every module's `init`, then every `start`) is followed by a check: each listed currency must
have a spender by then, or boot fails closed like every other boot error:

```
compliance.paidCurrencies lists 'Gems', but no enabled module registered a spender for it
(ctx.compliance.registerCurrencySpender); enable the module that owns 'Gems' or remove it from the list
```

Register in `init` (Economy does, for every listed currency) or in `start`. An empty or missing
list needs nothing. The check runs before the framework starts (step 6: queued requests, the
receipt handler), so no request or purchase ever meets a paid currency nobody can spend.

## 20. Additions in v1.6.0

Additive surfaces added in v1.6.0. Nothing above changed. The full design (failure rules, the
marker, the cutover) is [adopting.md](adopting.md); this section lists the API.

### 20.1 `ctx.data.importLegacy`: a one-time import of a player's old save (added in v1.6.0: adopting an existing game must bring every old save over, read-only, without a way to lose one)

```lua
ctx.data.importLegacy({ id, version, source, import = fn(tx, old, info), merge = fn?(tx, old, info),
                        receipts = fn?(old) -> ids, itemTag = "paid" | "free" })   -- in init, once
ctx.data.legacyStatus(player, id) -> marker?                                       -- read-only
ctx.data.isImport(tx) -> boolean                                                   -- kits relax caps
```

- Sources (`kind`): `"datastore"`, `"profileservice"` / `"profilestore"`, `"datastore2"`; read
  through a framework reader that has no write method. Key patterns use `{userId}` only.
- Runs inside the framework's load, before the player counts as loaded; reads first (they yield),
  then one non-yielding transaction that runs `import` (or `merge`) and writes the marker
  `_framework.imports[id]` in the same commit. Any failure kicks the player and changes no data.
- In an import transaction a refused `depsTx` call raises, `ctx.compliance` rolls and paid spends
  error, and items get the source `paid:legacy` (`itemTag = "free"`: `legacy`).
- Tests: `StudWork.test.legacyStore(seed)`, `harness({ legacy = store })`,
  `sim.server(world, { legacy = store })`; `tools/test-migration`.

### 20.2 The purchase bridge (added in v1.6.0: exactly one grant across the switch from an old game)

```lua
ctx.shop.legacyReceipts({ name, scope?, key = "{userId}_{purchaseId}", until? })   -- old history store
ctx.shop.onLegacyProduct(product, fn(receiptInfo, player) -> decision, { writesLegacyData = bool })
```

- `importLegacy.receipts` ids go to `_framework.legacyPurchases` (not pruned by the 200-entry cap).
- `onLegacyProduct` is a development bridge: `tools/adopt --verify` and `tools/publish --live`
  refuse while one is left; boot fails if a `writesLegacyData = true` handler meets an import.

### 20.3 Rarity and Compliance: odds preview at any luck, luck on a single item (added in v1.6.0: a game's eggs each carry their own luck)

```lua
Rarity.getOddsDetail(tableId, player?, luck?) -> OddsDetail?     -- luck: pure preview
Rarity.discloseItem(player, tableId, itemKey, luck) -> boolean
Rarity.clearItem(player, tableId, itemKey)
txApi.roll(tx, tableId, luck?, { item = itemKey, grant? })        -- also api.roll, purchaseOps.roll
ctx.compliance.discloseItem(player, sourceId, itemKey, luck) -> boolean
ctx.compliance.disclosedItem(player, sourceId, itemKey) -> OddsDetail?
ctx.compliance.clearItem(player, sourceId, itemKey)
ctx.compliance.roll(tx, sourceId, luck?, { item = itemKey }?)    -- and spendForRoll(..., luck?, opts?)
registerRandomSource(id, { ..., oddsAt = fn(player, luck) -> OddsDetail })  -- optional field
```

A paid roll with an item key needs that item's odds disclosed at exactly that (sanitized) luck,
plus `luckDisclosed` for luck ≠ 1; free rolls may use any luck. Details: adopting.md §6.

## 21. Additions in v1.6.1

Patch release: safety hardening of the v1.6.0 additions. Every change is optional and additive.

### 21.1 Gamepass lookups at join, and `ownsPass` inside a transaction (added in v1.6.1: a slow MarketplaceService held every join's save load for up to 5 s)

```lua
GameConfig.shop = { passPrefetchTimeout = 2 }  -- seconds, 0..5, default 2; anything else is a boot error
```

- A join waits at most `passPrefetchTimeout` for its `products.passes` lookups, then loads the
  save. Lookups that miss it finish in the background; `onPassOwned` still fires.
- `ctx.shop.ownsPass` inside a transaction never guesses an answer it doesn't have (pending,
  failed, or a pass never looked up): in a purchase handler the receipt is retried
  (`NotProcessedYet`, reason `pass_unknown`, nothing granted or recorded, even if the handler
  pcalls it); in any other transaction it errors and the transaction is discarded.
- Framework analytics event `PlayerLoadTiming` once per join (`totalSeconds`, `loadSeconds`,
  `passSeconds`, `passesPending`, `timedOut`).

### 21.2 Legacy code on a live server (added in v1.6.1: a place-file game can be published by hand without `tools/adopt --verify`)

```lua
ServerConfig.legacyList = { files = { { path = "src/server/Old.server.luau", checks = { "purchases" } } } }
-- the decoded studwork-legacy.json; the adopted boot script passes StudWorkBoot.LegacyList
```

On a live (non-Studio) server with list entries or any `ctx.shop.onLegacyProduct` bridge: one
`[StudWork]` warning at boot, naming the files and every bridge with its declared
`writesLegacyData`, and the analytics event `LegacyCodeLive` once per server. A missing or
malformed list is no list.

### 21.3 The purchase bridge, checked where it can be (added in v1.6.1)

```lua
ctx.shop.legacyReceipts({ name, scope?, key, until?, checkDays? })  -- checkDays: default 90
```

- `checkDays`: how many days after `until` the old history store is still checked; after that an
  old receipt grants normally. Positive numbers only.
- An `onLegacyProduct` handler declared `writesLegacyData = false` that writes an old store
  fails loudly in tests and, for the observed import keys, in Studio: the receipt
  answers `NotProcessedYet`, nothing is recorded, and `UNDECLARED LEGACY WRITE` names the product,
  module, store and key. Tests: `StudWork.test.legacyStore(...)` gains `dataStoreService()` and
  `watchWrites(fn)`. Live servers are not checked (adopting.md §4.3).


## 22. Additions in v1.6.2

Patch release: UI kit fixes. Every addition is optional; existing props keep their meaning.

### 22.1 A readable minimum text size (added in v1.6.2: odds item names rendered at about 7 px on phones)

```lua
GameConfig.theme = { metrics = { minTextSize = 11 } }  -- real on-screen pixels, 6..32, default 11
```

With the default text sizes, no UI kit text renders below `minTextSize` after the kit's own
scales (the responsive scale, at least 0.85, and a Modal's fit scale, never below
`ModalFit.minScale`). The kit doesn't enlarge text to meet the metric: a theme that raises
`minTextSize` must raise `metrics.text` to match (smallest size x 0.85 >= `minTextSize`), and text
under a game's own extra UIScale is the game's to check. `metrics.text.min` (design pixels, now 14
by default) stays the floor of scaled text. Pure helpers under `ReplicatedStorage.UI`: `ModalFit.minScale(tokens)` (the smallest scale
`UI.Modal` applies) and `ModalFit.contentHeight(screenY, outerScale, fitScale, chrome, content, floor)`
(the height of a Modal's scrolling content in design pixels).

### 22.2 Measured wrapped text (added in v1.6.2: the odds region notice showed one line of three)

```lua
e(UI.WrappedText, { text = "...", textSize = "small", font = "bold", color = "text",
	backgroundColor = "warning", padding = 8, layoutOrder = 1, onHeight = function(h) end })
```

Its height is measured with `TextService:GetTextBoundsAsync` at its real width and re-measured when
the width, text, font or size change; use it for any multi-line kit text instead of a TextLabel
with `TextWrapped` and `AutomaticSize`.

### 22.3 UI kit props (added in v1.6.2)

- `UI.OddsTable`: `title = false` omits its own heading (for a table inside a window that already
  has a title). Names wrap to two lines and end in "…"; tapping one shows the full name.
- `UI.Modal`: content taller than 88% of the screen scrolls. Render it in a ScreenGui with
  `ZIndexBehavior = Sibling`; under `Global` the backdrop covers the panel and the Modal warns once.
- `UI.ItemCard`: text rows keep readable sizes and the icon takes the space left
  (`ItemCardLayout.iconSize`); give the card at least 120 x 160 design px for every optional row
  (a smaller card clips its contents).

## 23. Additions in v1.7.0

Minor release: six modules games need (Notifications, Leaderboards, Badges, TextFilter,
environments and flags, localization). Every surface below is new and optional; nothing above
changed meaning. The kit modules' own APIs are on their pages
([notifications](kits/notifications.md), [leaderboards](kits/leaderboards.md),
[badges](kits/badges.md), [textfilter](kits/textfilter.md)); this section lists the
**framework** surfaces they (and any third-party module) build on. The framework names Roblox
services here, never a kit.

### 23.1 `StudWork.env` and `ctx.env`: which environment this is (added in v1.7.0: test-only behaviour must be impossible on the live place, which needs the framework to know where it runs)

```lua
GameConfig.environments = { test = { placeIds = { number }?, universeIds = { number }? }?,
                            live = { placeIds = { number }?, universeIds = { number }? }? }
StudWork.env.name() -> "studio" | "test" | "live"   -- both sides, after StudWork.start
StudWork.env.placeId() -> number
StudWork.env.universeId() -> number                  -- game.GameId
ctx.env                                              -- the same frozen table, server ctx
```

- `"studio"` when running in Studio; `"test"` when `game.PlaceId` is listed in
  `environments.test.placeIds`; `"live"` when it is in `environments.live.placeIds`; `"test"` when
  `game.GameId` is in `environments.test.universeIds` and `environments.live.universeIds` lists the
  live universe (a test universe is trusted only once it is known to differ from live; without a
  live universe it is ignored with a boot warning, so a live universe listed under `test` can never
  make live servers test); otherwise `"live"` (an unlisted place is live, with a boot warning when
  `environments.live` is set and doesn't list it either). **An id listed under both `test` and
  `live` is a boot error.**
- `environments` is framework-level config (top level of `GameConfig`, §11). In a game it is
  generated from `deploy.json` into `src/shared/Config/Environments.luau` by `tools/sync-projects`
  (`--check` fails on drift, and when deploy.json's test and live ids are equal). Placeholder
  ids are left out; the test universe id is written only when it differs from the live one.
- Replicated as `state.framework.env`.

### 23.2 `StudWork.flags` and `ctx.flags`: feature flags (added in v1.7.0: features have to be switched per environment, and switched off live without a restart)

```lua
GameConfig.flags = { [name] = { default: boolean, studio: boolean?, test: boolean?, live: boolean?,
                                testOnly: boolean?, serverOnly: boolean?, override: boolean?,
                                description: string? } }
GameConfig.flagOverride = { enabled: boolean?, keyPrefix: string?, refreshSeconds: number? }
                                               -- defaults false, "flag_", 30 (5..600)
StudWork.flags.isOn(name) -> boolean           -- both sides; an undeclared name errors
StudWork.flags.onChanged(name, fn(on: boolean)) -> Connection
StudWork.flags.all() -> { [string]: boolean }  -- frozen; on the client only replicated flags
StudWork.flags.source(name) -> "config" | "override"
ctx.flags                                      -- the same table, server ctx
```

- Value = live override (if allowed) > the environment's field > `default`.
- **A `testOnly` flag whose live value would be true is a boot error** (collected with the other
  config errors). In `"live"` an override can't switch a `testOnly` flag on (a warning in the log;
  analytics is per player, so there is no framework-level event).
- The live override reads Roblox experience configs on the server (`ConfigService`, keys
  `<keyPrefix><name>`, booleans only) in a background thread after boot, refreshes on
  `UpdateAvailable` at most every `refreshSeconds`, polls `Outdated` on the same interval, and never
  blocks boot or errors to callers. Changes fire `onChanged` and replicate.
- Replicated as `state.framework.flags` (every flag without `serverOnly`). The client resolves
  the same config with the same pure resolver at start, then takes the server's values.
- `serverOnly` hides a flag's **value**, not its definition (`GameConfig` reaches every client):
  on the client `isOn`/`onChanged`/`source` error for it and `all()` leaves it out.
  `ServerConfig.flags` (same fields, `serverOnly` implied, never replicated) hides the definition
  too; a name in both tables is a boot error.
- A client flag value only changes presentation: whatever a flag gates must be checked on the
  server.
- `StudWork.flags` and `StudWork.env` are facade members of the framework, not modules: they have no
  `ModuleRef` and `StudWork.use` doesn't accept them (the same rule as Data or Policy, §4).
- Console: `flags`, `flags set <name> <true|false|clear>` (Studio only, this server).
- Details: [environments.md](kits/environments.md).

### 23.3 `ctx.data.ordered(name)`: an ordered store per module (added in v1.7.0: all-time leaderboards need OrderedDataStore, and hard rule 4 keeps DataStoreService inside the framework)

```lua
local board = ctx.data.ordered(name)          -- in init or later; doesn't yield
board.get(key) -> (ok, value: number?)        -- yields
board.set(key, value) -> (ok, reason?)        -- yields
board.increment(key, delta) -> (ok, newValue | reason)
board.update(key, fn(old: number?) -> number?) -> (ok, newValue | reason)  -- atomic, fn may re-run;
                                              -- fn returning nil cancels: (true, current value);
                                              -- fn raising, or returning a non-integer, raises in the caller
board.remove(key) -> (ok, reason?)
board.top(count, order: "desc" | "asc", minValue?, maxValue?) -> (ok, { { key, value } } | reason)
```

- One OrderedDataStore per (module, name): store name `SW/<Module>/<name>` (the framework prefix
  keeps it apart from an adopted game's own ordered stores; at most 50 characters, checked when
  `ordered` is called), `_Studio` suffix in Studio like `ctx.data.shared` (§19.1). A module can't
  open another module's store.
- `key` is a string of at most 50 characters (callers use the user id). Values are integers
  (OrderedDataStore stores integers): a non-integer or non-finite value is an error in the caller
  (`board.set` errors, it doesn't round). `count` is 1..100 (one page).
- **Budget:** before each call the framework checks this server's remaining request budget for
  that request type (`DataStoreService:GetRequestBudgetForRequestType`, ordered types:
  `OrderedRead`/`OrderedWrite`/`OrderedList`/`OrderedRemove` in Roblox's limits table) and refuses
  with `(false, "budget")` instead of queueing behind the player saves. A throttled or failed call
  is retried twice with backoff (1, 2 s), then `(false, "failed")` and one warning per store per
  minute. It never raises for a platform failure.
- **`increment` is never retried** (a timed-out call may have committed, and a retry would count
  twice): a failure returns `(false, "failed")` and may or may not have applied. Prefer `set` or
  `update` with an absolute value, which are idempotent; the Leaderboards kit never increments.
- **Experience-level limits** also apply (ordered list `300 + 2 x CCU`, write `300 + 20 x CCU` per
  minute, shared with Open Cloud): many small servers can exceed them while each is under its own
  budget. An experience-level throttle error backs off **every** ordered store of that module
  (30 s, doubling to 5 min; calls return `(false, "budget")` meanwhile), not one call.
- Yields: call from a spawned thread or a lifecycle loop, never inside `ctx.tx`, `init` or `start`.
- Studio without API access: an in-memory store with one warning. Tests: in-memory (§23.10).

### 23.4 `ctx.data.sortedMap(name)`: a MemoryStore sorted map per module (added in v1.7.0: periodic leaderboards and the notification due list need fast, expiring, cross-server data)

```lua
local map = ctx.data.sortedMap(name)                    -- doesn't yield
map.get(key) -> (ok, value: any?, sortKey: (number | string)?)
map.set(key, value, expirySeconds, sortKey?) -> (ok, reason?)
map.update(key, fn(old, oldSortKey) -> (new, newSortKey)?, expirySeconds) -> (ok, new | reason)
map.remove(key) -> (ok, reason?)
map.range(direction: "asc" | "desc", count, lower?, upper?) -> (ok, { { key, value, sortKey } } | reason)
                                       -- lower/upper: { key?, sortKey? }, exclusive, as Roblox's
```

- One sorted map per (module, name): `SW/<Module>/<name>`. A module can't reach another's maps.
  `name` may contain `/` (a leaderboard's period: `"daily/20404"`).
- **A sorted map is one MemoryStore partition**: Roblox starts throttling at about 30,000 request
  units a minute on one partition and 100,000 on one structure. A module whose map every server
  hits must shard it (several names) or scale its cadence with the server count
  (`ctx.data.census()`, §23.5); the kit pages say how they do.
- Roblox's limits are enforced before the call: key at most 128 characters, sort key a number or
  a string of at most 128 characters, value JSON-safe and at most 32 KB encoded, expiry 1..3 888 000
  seconds (45 days; required, there is no default), `count` 1..200. Breaking one is an error in
  the caller.
- `update`'s `fn` returning nil cancels the write and the call answers `(true, nil)` (Roblox
  semantics); it may run more than once. An error raised inside `fn` is an error in the caller
  (it raises; it does not return `false`), like the other caller errors above.
- **Budget:** request units are counted per server per minute (a `range` costs one unit per row
  returned plus one for the partition scanned, Roblox's rule); over this server's share (`GameConfig.storeBudgets`, §23.5) a call
  returns `(false, "budget")` without calling Roblox. Throttled (`RequestThrottled`,
  `PartitionRequestsOverLimit`, `DataStructureRequestsOverLimit`, `TotalRequestsOverLimit`) or
  failed calls are retried twice with backoff, then `(false, "throttled" | "failed")`; a full
  memory quota (`TotalMemoryOverLimit`, `DataStructureMemoryOverLimit`,
  `DataStructureItemsOverLimit`) returns `(false, "memory_full")` immediately. No raises for
  platform failures.
- **Memory:** every write that can grow memory is charged to the module's memory share
  (`storeBudgets.memory`, §23.5) before the call: `set` charges the item's full estimated size
  (key + encoded value + sort key + 32 bytes), `update` the difference from the old value its `fn`
  saw, `remove` gives back what this server charged for that key. Over the share it returns
  `(false, "memory_budget")` without calling Roblox, so one module can't fill the experience-wide
  quota every module shares. Writes that don't grow memory are never refused for memory. Use
  `update` for items you rewrite: a `set` over an existing item is charged again.
- Yields, same rules as §23.3. Studio: Roblox keeps Studio memory stores separate from live;
  without API access an in-memory map with one warning. Tests: in-memory (§23.10), shared between
  sim servers.

### 23.5 `GameConfig.storeBudgets` (added in v1.7.0: two modules sharing one server's store quota need a cap that leaves room for player saves)

```lua
GameConfig.storeBudgets = {
	orderedReserve = 0.25,   -- fraction of each ordered request type's budget kept free, 0..0.9
	memoryUnits = { base = 20, perPlayer = 20 },    -- this server's MemoryStore units per minute
	memory = {                                      -- MemoryStore memory, experience-wide
		reserve = 0.2,        -- fraction of the quota no module may use, 0.05..0.9
		defaultShare = 0.25,  -- each module's share of the quota unless listed, 0.01..1
		shares = {},          -- { [ModuleName] = fraction }
	},
	censusSeconds = 60,       -- how often each server reports to and reads the census, 30..600
}
ctx.data.census() -> { servers: number, players: number, peakPlayers: number, at: number }?
                                                -- nil until the first census read; doesn't yield
```

- Ordered stores: a call is refused while the remaining budget for its type is at or below
  `orderedReserve` x the per-minute limit for the current player count (Roblox: list
  `5 + 2 x players`, read `60 + 40 x players`, write and remove `30 + 5 x players`, per server;
  an `update` uses one read and one write).
  Player saves use the standard DataStore request types, which ordered calls don't consume.
- **MemoryStore request units:** the cap is one per server, shared by every module (not per module;
  only the memory below has per-module shares). A server with no players has `base` = 20 units a
  minute: with a ledger operation at about 3 units, that is a handful of Notifications sends a
  minute (about 3), so a server that is empty for long sends little. The quota (`1000 + 120 x CCU` units per minute) is
  experience-wide; there is no per-server budget to read, so each server caps itself at
  `base + perPlayer x playersInServer`. The bound, honestly: the experience uses at most
  `20 x servers + 20 x CCU`; with at least one player per server that is at most `40 x CCU`, a
  third of the quota, and 100 one-player servers use 4,000 of 13,000. Only many empty servers
  (reserved servers waiting for players) can push it higher: each costs `base`.
- **The census:** every `censusSeconds` each server adds `{ servers = 1, players = n }` to the
  current time bucket of a framework-owned sorted map (`SW/_/census`, an atomic `update`, expiry
  10 min) and reads the last complete bucket. Past 500 servers (the last reading) the bucket is
  split so no one key takes every server's update: `ceil(servers / 500)` shards (at most 16), shard
  `k > 0` in its own map `SW/_/census/<k>` (its own partition); each server writes one and reads them
  all (one get each) and adds them up. The bucket gives `servers` and `players` (= CCU) for the whole
  experience, at most two buckets old. The day's peak player count is kept for 9 days, and
  `peakPlayers` is the highest of the last 8 days. Cost: about 3 request units per server per
  `censusSeconds` (an `update` counts as a read and a write; charged to the framework, not a
  module, and counted but never refused), plus one per extra bucket shard, plus 2 for each module
  that had new memory charges that cycle and one range read on a server's first cycle. Each census
  map takes about `servers x (1 + 2 / shards)` units a minute at the default (every server reads
  every shard; a shard's writers are `servers / shards`): about 11,000 at 10,000 servers, under a
  partition's limit of about 30,000. The usage items `u/<Module>` stay single keys (their update
  answers the experience-wide total): a server updates one only in a cycle with new charges. `ctx.data.census()` gives modules the
  last reading, so they scale their cadences with the server count.
- **MemoryStore memory:** the quota (`64 KB + 1.2 KB x users`) is experience-wide, and Roblox only
  lowers it 8 days after the users leave, so the framework estimates it as
  `64 KB + 1.2 KB x peakPlayers` (until the first census: this server's players). Each module's
  sorted-map writes are charged by size (§23.4); every server adds its charges per module to a
  usage item in the census map (bucketed by expiry hour, so expired items drop out without
  anyone deleting anything), once per `censusSeconds`, and reads the totals back. A growing write is
  refused with `"memory_budget"` when the module's total would pass `share x quota`, or all
  modules' together `(1 - reserve) x quota`. The totals lag by up to `censusSeconds`, which the
  reserve absorbs. Shares adding up to more than `1 - reserve` are a boot warning (the total cap
  still holds). The estimate assumes items expire within 8 days, the quota's own memory; the v1.7.0
  kits keep to that.
- All of it is framework-level config; a bad value is a boot error. In Studio and tests the same
  accounting runs on the in-memory stores.

### 23.6 `ctx.services.get(name)`: engine services for modules, replaceable in tests (added in v1.7.0: Badges, TextFilter and Leaderboards call Roblox services that Lune specs must fake)

```lua
local BadgeService = ctx.services.get("BadgeService")
```

- Live: `game:GetService(name)`. In the harness and the sim: the fake given in
  `harness({ services = { [name] = fake } })`, or a stub whose every method errors
  `no test fake for BadgeService: pass harness({ services = { BadgeService = ... } })`.
- Allowed names: `BadgeService`, `TextService`, `UserService`, `LocalizationService`, `Players`
  (the list is `Services.ALLOWED` in the framework; later additions are additive).
  Refused with an error naming the framework surface to use instead: `DataStoreService`
  (`ctx.data`), `MemoryStoreService` (`ctx.data.sortedMap`), `MarketplaceService` (`ctx.shop`),
  `HttpService` (`ctx.openCloud`), `MessagingService` (`ctx.data.messages`), `ConfigService`
  (`ctx.flags`), `PolicyService` (`ctx.policy`).
- Code that calls `game:GetService` directly still works live; it just can't be faked in specs.
  The `purchases` lint check makes the services with a framework surface framework-only in code
  too: `DataStoreService`, `MemoryStoreService` (as before) and, from v1.7.0, `ConfigService`,
  `:GetSecret(`, `:RequestAsync(` and `:PostAsync(`, each with a planted case in the self-test.
  Plain `HttpService` (`JSONEncode`, `GenerateGUID`) stays allowed.

### 23.7 `ctx.openCloud`: Open Cloud from a game server (added in v1.7.0: experience notifications are sent through Open Cloud, with the key in Roblox's secrets store)

```lua
ServerConfig.openCloud = {                       -- server-only, never replicated
	perMinute = 600,                             -- this server's Open Cloud requests per minute
	secrets = { [secretName] = { modules = { string }, methods = { string }, paths = { string } } },
}
ctx.openCloud.available(secretName) -> boolean   -- doesn't yield; cached per secret and module
ctx.openCloud.request({ secret = string, method = "GET" | "POST" | "PATCH" | "DELETE",
                        path = string, body = table? }) -> (ok, status: number?, body: any?)
```

- **Scoped, deny by default.** A request is made only when `ServerConfig.openCloud.secrets` has an
  entry for that secret that lists the **calling module**, the method, and a path pattern the path
  matches (`*` matches exactly one path segment; there is no `**`). Anything else returns
  `(false, nil, "not_allowed")` without a request, with one warning per (module, secret) naming
  the missing part. The table lives in `ServerConfig`, so clients never see which secrets exist,
  and a module can't use another module's secret.
- **Hard-refused families**, whatever the config says, with an error naming the surface to use
  (the same pattern as `ctx.services` refusals): `universes/*/data-stores/...` and
  `.../ordered-data-stores/...` (`ctx.data`, `ctx.data.ordered`), `.../memory-store...` including
  the flush (`ctx.data.sortedMap`), `.../configs...` (`ctx.flags`), and Luau execution
  (`.../luau-execution...`). A path in one of them returns `(false, nil, "forbidden")` and warns.
  This keeps hard rule 4 and the store budgets true for code holding a broad key.
- The game owner gives each key only the permission its entry needs (for notifications,
  `user.user-notification:write` on this universe); the framework can't see a key's scopes, so
  the allow-list is the second fence, not a replacement.

- Live: `HttpService:RequestAsync` to `https://apis.roblox.com/cloud/v2/<path>` with the
  header `x-api-key = HttpService:GetSecret(secret)` and `content-type: application/json`
  (the only two headers Roblox allows for Open Cloud from a game server). `path` is relative,
  must not contain `..` or a scheme. The secret value is never logged or returned: logs and
  analytics show the secret's **name**.
- `available` is false when the calling module isn't allowed the secret, HTTP requests are off,
  the secret doesn't exist (a local Studio playtest without a local secret), or `GetSecret`
  errors; the first unavailable call logs once. `request` on an unavailable secret returns
  `(false, nil, "no_secret")` without a request.
- Rate: at most `ServerConfig.openCloud.perMinute` (default 600; Roblox allows 2500 Open Cloud
  requests per server per minute) requests per server; over it `(false, nil, "budget")`.
  A 429 or 5xx is returned to the caller (modules decide retries). Request and response bodies
  are never logged.
- No API key, URL or secret value appears in the repo; game docs tell the owner to create the key
  and the secret (`docs/framework/kits/notifications.md`).
- Tests: `harness({ openCloud = StudWork.test.fakes.openCloud(), secrets = { [name] = true },
  serverConfig = { openCloud = { secrets = { ... } } } })`. Specs: a path outside the allow-list,
  another module's secret, a wrong method and a hard-refused family are each refused with no
  request reaching the fake.

### 23.8 `ctx.policy.allows(player, field)` and `ctx.policy.restricted(player, field)` (added in v1.7.0: TextFilter honours `IsContentSharingAllowed`; a restriction field must never read as "allowed" while unknown)

```lua
ctx.policy.allows(player, "IsContentSharingAllowed") -> boolean        -- permissions
ctx.policy.restricted(player, "IsSubjectToChinaPolicies") -> boolean   -- restrictions
```

- The boolean fields of `PolicyService:GetPolicyInfoForPlayerAsync`, in two kinds, each with its
  own call so that "unknown" always reads as the safe answer:
  - **permissions** (`true` = allowed): `IsContentSharingAllowed`, `AreAdsAllowed`,
    `IsPaidItemTradingAllowed`, `IsEligibleToPurchaseSubscription`. `allows` is **fail closed**:
    `false` until the lookup succeeds, and `false` unless the answer says `true`.
  - **restrictions** (`true` = restricted): `ArePaidRandomItemsRestricted`,
    `IsSubjectToChinaPolicies`. `restricted` is **fail closed** the other way: `true` until the
    lookup succeeds, and `true` unless the answer says `false`.
    `restricted(player, "ArePaidRandomItemsRestricted")` equals `paidRandomRestricted(player)`
    (the Studio console override included).
- Each call errors for the other kind (the message names the right call) and for an unknown field:
  a `false` from `allows` on a restriction would read as "not restricted" while the lookup is
  unknown. Both read the lookup Policy already makes at join (no extra request).
  `ctx.policy.isKnown(player)` tells the cases apart.
- Harness: `policy = { [userId] = { IsContentSharingAllowed = false, ... } }` (a table) next to the
  existing `true` / `"fail"` values.

### 23.9 Strings: `defineModule.strings`, `GameConfig.strings`, `ctx.text`, `StudWork.text`, `UI.text` (added in v1.7.0: the UI kit and the framework speak English only, and games couldn't reword or translate them)

```lua
StudWork.defineModule({ ..., strings = { ["<Module>.<name>"] = "English {param}" } })
GameConfig.strings = { [key] = "English" }                  -- reword any key; add game.* keys
GameConfig.localization = { sourceLocale = "en", useTranslators = true }
ctx.text.format(player, key, args?) -> string               -- server, in the player's language
ctx.text.english(key, args?) -> string                      -- server
StudWork.text(key, args?) -> string                         -- client
UI.text(key, args?) -> string ; UI.useText(key, args?) -> string   -- UI kit (hook re-renders)
```

- `strings` is a new optional definition field: keys must start with `<ModuleName>.`, values are
  non-empty strings (definition errors otherwise). It may also be `function(config) -> table`
  (the module's merged config, run once at boot after validation, like `theme`, §19.3), for keys
  built from config (`Leaderboards.board.<boardId>`, `Badges.badge.<key>`). `ui.*` defaults belong
  to the UI kit, `framework.*` to the framework, `game.*` to the game.
- Resolution: the player's Roblox translator (`FormatByKey`, in `pcall`) > `GameConfig.strings` >
  the owner's English default > the key itself with one warning. Never an empty string.
- Format strings use Roblox's syntax (`{name}`, `{1}`), so the same text works in a Roblox
  localization table.
- Details and the `strings` lint check: [localization.md](kits/localization.md).

### 23.10 `StudWork.test` additions (added in v1.7.0)

- Harness options: `env` (`"studio" | "test" | "live"`), `placeId`, `universeId`,
  `services = { [name] = fake }`, `openCloud = fake`, `secrets = { [name] = true }`, `locale`,
  `translator = fake`, `storeBudgets`, `census = { servers, players, peakPlayers? }` (a fixed
  census reading), and `policy` entries that are tables of fields (§23.8). `serverConfig` (existing)
  carries `openCloud` and `flags`. The framework's own `ConfigService` use takes
  `services.ConfigService`.
- In-memory ordered stores and sorted maps behind `ctx.data.ordered` / `ctx.data.sortedMap`, with
  the Roblox limits checked as live, expiry on the harness clock (`h:tick`), request counting
  against the budgets and failure injection: `h:orderedStore(moduleName, name)` and
  `h:sortedMap(moduleName, name)` return the backing fake (`entries()`, `failNext(n, code?)`,
  `calls`). Several harnesses given the same `store = StudWork.test.memoryStore()` share them; in
  the sim every server shares the World's (with `world:failNext`), and the census counts the sim's
  servers. The in-memory sorted maps also apply Roblox's per-structure and per-partition request
  limits (`DataStructureRequestsOverLimit`, `PartitionRequestsOverLimit`; the numbers are options,
  so a spec can make them small) and an experience memory quota (`quotaBytes`, giving
  `TotalMemoryOverLimit`). The in-memory ordered store reuses the sim World's and the legacy
  adapter's existing ordered backend rather than a second fake.
- `StudWork.test.fakes`: `badgeService(opts)`, `textService(opts)`, `userService(opts)`,
  `configService(opts)`, `openCloud(opts)`, `translator(opts)`,
  `experienceNotificationService(opts)` (for client-part specs). Each records its calls and
  takes `failNext(n)`. Options are on the module pages.
- Client runtime test options: `env`, `placeId`, `locale`, `translator`, `flags` (the replicated
  values), so client parts and `UI.text` are testable in Lune.

### 23.11 Types (added in v1.7.0)

`Types.luau` gains, all optional or new: `EnvName`, `EnvironmentsConfig`, `FlagDef`,
`FlagsConfig`, `FlagOverrideConfig`, `FlagsAPI`, `EnvAPI`, `OrderedStore`, `SortedMapStore`,
`SortedMapItem`, `StoreBudgetsConfig`, `ServicesAPI`, `OpenCloudAPI`, `OpenCloudRequest`,
`TextAPI`, `StringsTable`, `LocalizationConfig`, `MemoryBudgetConfig`, `CensusInfo`,
`OpenCloudConfig`, `OpenCloudSecretRule`; `ModuleContext` gains `env`, `flags`, `services`,
`openCloud`, `text`; `ScopedData` gains `ordered`, `sortedMap`, `census`; `PolicyAPI` gains
`allows`; `GameConfig` gains `environments`, `flags`, `flagOverride`, `storeBudgets`, `strings`,
`localization`; `ServerConfig` gains `openCloud`, `flags`; `ModuleDefinition` gains `strings`
(a table or a function of config). Nothing is renamed or narrowed.

### 23.12 Two new lint checks (added in v1.7.0)

- **`strings`**: hard-coded English in the UI kit, kit client parts and framework client code
  (not examples, not games), and string keys without an English default
  ([localization.md](kits/localization.md)).
- **`textfilter`**: a client-supplied string reaching a player or a shared store (replication,
  events to any player including its author, mail, shared and sorted-map/ordered writes,
  notification params, instance text) without TextFilter, or a whole TextFilter record reaching
  one, in game, example and kit server code; a best-effort, same-function heuristic
  ([textfilter.md](kits/textfilter.md)).
- The existing **`purchases`** check also gains `ConfigService`, `:GetSecret(`, `:RequestAsync(`
  and `:PostAsync(` as framework-only (§23.6).

Both have planted violations in `guardrails --self-test`, honour `-- guard: allow <check>` with a
reason, and join the checks a legacy list may name (`textfilter` only; `strings` doesn't scan game
code).
