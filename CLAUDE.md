# CLAUDE.md — rules for every agent in this repo

Roblox multi-game monorepo. One shared core (`packages/core`, `packages/ui`), many games
(`games/<name>`), each published as its own Roblox experience. Language: **Luau, `--!strict`**.
Read `docs/decisions.md` for why things are the way they are.

## Hard rules

1. **Games never edit `packages/core` or `packages/ui`.** Need something? Add an entry to
   `CORE_REQUESTS.md`. Only the core owner changes core.
2. **Core's interface is additive only.** `packages/core/shared/Types.luau`,
   `packages/core/shared/Modules.luau` and `packages/core/shared/net/core.blink` gain things;
   nothing is renamed or removed. Mark old calls `-- @deprecated <replacement>` and keep them
   working. Record every change in `packages/core/CHANGELOG.md`. (core-v1.1.0 made a one-off set
   of breaking changes before any game existed, listed under "Breaking (pre-games)".)
3. **The server is authoritative.** Clients only send requests. The server validates every argument
   (type, range, ownership) and every remote is rate-limited (`core/server/Net`). Never trust
   amounts, item ids, uids, prices or positions from a client. Robux purchases go through
   `Shop.onProduct` (receipt-safe data-only handlers, see below), never through a remote.
4. **Every balance number lives in the game's Config** (`games/<name>/src/shared/Config`). Core reads
   it through the GameConfig passed to `Core.start`; core code has no balance defaults.
5. **No secrets in the repo.** Open Cloud keys come from env vars or the git-ignored `.env`.
6. **Look before you use** a library: check it is maintained, confirm version and install method,
   pin exact versions (`=x.y.z` in `deps/wally.toml`, `@x.y.z` in `rokit.toml`), record the choice in
   `docs/decisions.md`. Not on Wally → vendor into `packages/vendor/<name>/` with its LICENSE and a
   SOURCE.md (url, commit/version, why).
7. **Git:** feature branches + worktrees, local commits only. Never push, never add remotes. Commit
   only your own paths (no `git add -A` in shared trees).
8. **Paid random items:** show exact odds (`Rarity.getOdds`), pass `{ paid = true }` to rolls bought
   with Robux (blocked for `Policy.paidRandomRestricted` players), and don't let restricted players
   trade items from paid random sources. Rolls costing a currency that is sold for Robux are paid
   random items too: list such currencies in `balance.paidCurrencies`. A Robux product handler must
   never take money for nothing from a restricted player: grant a fixed non-random fallback.
9. **No text-chat dependence** (chat is age-gated): pings, emotes, roles.
10. **Ask the user** before installing anything outside the repo or with sudo, spending money,
    publishing to Roblox, or touching files outside the repo root.
11. **Luck and disclosed odds (core-v1.2, N4).** A *paid* roll (Robux: a `paid = true` table or
    `tx.roll`; or a `cost` in `balance.paidCurrencies`) whose effective luck is not 1 **errors**.
    The only exception: the table sets `luckDisclosed = true` and the player's client has already
    received odds computed with that exact luck (`Rarity.setLuck` re-sends them; core checks what
    was actually sent). So: give luck with `Core.Rarity.setLuck(player, luck, tableId?)`, never as
    a hidden argument to a paid roll; show `state.odds[tableId]` (it carries `luck`) with
    `UI.OddsTable`. Free rolls may use any luck.
12. **Game remotes go through `Core.Net.handle(name, blinkEvent, { rate, burst }, fn)`**, never
    `OnServerEvent`/`OnServerInvoke` or hand-made RemoteEvents. Validate every argument in `fn`.
13. **Full inventory is not a failure.** A Mail handler that can't accept a message now returns
    `false`: the message waits in the player's mailbox (`Core.Mail.pending/claim`, HUD badge)
    with no time limit. Only thrown errors are retried and dead-lettered. Mail kinds starting
    with `core_` are reserved. Never mail items to users who may never come back: ProfileStore
    drops the oldest of more than 1000 queued messages (known issue R1). Pick recipients from
    recently active players and cap gifts per recipient. Rolls of a table priced in a paid
    currency are paid rolls unless you pass `{ free = true }` (a reward nobody paid for).
14. **Register items before `Core.start` when you can** (put them in `Config.items`). Items
    registered later are allowed: core re-sends the disclosed odds (N3), but the odds a player
    saw before that are stale until the update arrives.
15. **`tools/lint` guardrails must stay clean** (`tools/lune/guardrails.luau`): no core module
    outside `GameConfig.modules`, no edits under `packages/` from game work (branch `game/<name>`),
    no balance number literals outside `src/shared/Config/` (put game-own numbers in
    `Config/Tuning.luau`), no raw remotes. `-- guard: allow <check>` on a line is a last resort
    and needs a reason on the line above.

## Folder map

```
packages/core/shared/   ReplicatedStorage.Core        facade (init.luau), Types, Modules (module
                                                      manifest), Palette, RarityTiers, Sounds,
                                                      Validate, ConfigValidate, Signals,
                                                      HandlerList, PlotLayout/, net/core.blink
packages/core/server/   ServerScriptService.CoreServer bootstrap + module loader (init.luau),
                                                      Context (ctx + internal types), Tx (data
                                                      transactions), Console, Net/ (Blink +
                                                      rate limits), one folder per service:
                                                      Data Mail Items Policy Rarity Inventory Economy
                                                      Upgrades Rebirth Offline Streak Friends Events
                                                      Shop Analytics Plot Replication
packages/core/client/   ReplicatedStorage.CoreClient  bootstrap, Actions, Net/, State/ Feedback/
                                                      Input/ Hud/
packages/core/tests/    (not in the place)            Lune harness + runner
packages/ui/            ReplicatedStorage.UI          React-lua component kit + Theme
packages/vendor/        ServerStorage.Vendor          vendored libraries (currently none)
deps/                   wally.toml; Packages -> ReplicatedStorage.Packages,
                        ServerPackages -> ServerStorage.ServerPackages
games/<name>/           default.project.json, deploy.json, README.md, src/{server,client,shared/Config}
                        src/shared -> ReplicatedStorage.Game, src/server -> ServerScriptService.Game,
                        src/client -> StarterPlayerScripts.Game
templates/new-game/     copied by tools/new-game (a working copy of _sandbox)
tools/                  lint, test, typecheck, net, install, new-game, publish
docs/                   decisions.md, known-issues.md, research/, games/<name>.md
```

## The interface (summary — `Types.luau` is the source of truth)

```lua
local Core = require(ReplicatedStorage.Core)
Core.start(Config)                                   -- client (once)
Core.start(Config, ServerConfig)                     -- server (once); ServerConfig = { admins }
Core.isEnabled("Rebirth") -> boolean / Core.config() / Core.isStarted() / Core.version
-- server
Core.Items.register(defs) / .get(id) / .all() / .byTag(tag) / .incomeOf(instance)
Core.Rarity.roll(tableId, player, luck?, { paid?, grant?, reason? }) -> (ItemDef?, RollInfo) -- luck nil = getLuck
Core.Rarity.getOdds(tableId, luck?) -> { [itemId]: probability } / .tiers()
Core.Rarity.getOddsDetail(tableId, player?) -> OddsDetail? -- items, mutations, outcomes, pity, luck
Core.Rarity.setLuck(player, luck, tableId?) / .getLuck(player, tableId?) -> number   -- rule 11
Core.Economy.grant/spend(player, amount, reason, currency?) -> boolean / .balance(player, currency?)
Core.Economy.addIncomeSource/removeIncomeSource(player, sourceId, perSec)
Core.Economy.addMultiplier(player, id, mult, expiresAt?, persist?) / .removeMultiplier / .getMultiplier / .getRate
Core.Inventory.add(player, itemId, opts?) -> ItemInstance? / .remove / .get / .list / .count / .cap
Core.Inventory.transfer(from, to, uid, reason) -> (ok, err?) / .canTrade(player)   -- same server
Core.Inventory.sendGift(from, toUserId, uid, reason?) -> (ok, err?)  -- any user, via Mail (outbox)
Core.Plot.get(player) -> Model? / .owner(plot) / .display(player, uid, slotId?) / .clearDisplay / .slots / .onAssigned
Core.Upgrades.level/cost/purchase(player, upgradeId)
Core.Rebirth.canRebirth/rebirth/cost/multiplier(player)
Core.Offline.onReturn(fn(player, secondsAway))        Core.Streak.onDaily(fn(player, day)) / .get
Core.Friends.onCoPlay(fn(player, friends, "server"|"invite"|"private")) / .friendsInServer
Core.Events.schedule(id, schedule?, fn(ctx)) / .trigger(id, by?) / .isActive / .onEnded
Core.Shop.onProduct(product, fn(data, receipt, tx)) / .ownsPass / .onPassOwned  -- see "Purchases"
Core.Policy.paidRandomRestricted(player)
Core.Data.get / .update(player, fn) / .onLoaded / .isLoaded / .getGame / .updateGame / .saveAsync
Core.Mail.send(userId, kind, payload, key?) / .onReceive(kind, fn(player, payload, info) -> false?)
Core.Mail.pending(player) -> { MailboxEntry } / .claim(player, messageId) -> (ok, err?)  -- mailbox
Core.Net.handle(eventName, blinkServerEvent, { rate, burst }, fn(player, ...))   -- game remotes
Core.Analytics.funnel(player, step) / .economy(player, flow, currency, amount, type, sku?) / .custom
Core.Signals.DataLoaded, DataChanged, CurrencyChanged, ItemAdded, ItemRemoved, ItemDisplayed, ...
-- client
Core.Client.state()                                   -- Charm atom: ReplicatedState of the local player
Core.Client.Feedback.pop(text, position?, rarity?) / .flash(rarity) / .sound(key) / .shake(intensity?)
Core.Client.Input.device() / .deviceChanged / .bind(actionId, binding, fn) / .unbind
Core.Client.Actions.display/clearDisplay/rebirth/upgrade/roll/gift/triggerEvent/funnel/claimMail
Core.Client.Hud.mount({ nextGoal = fn, onMailbox = fn }) / .unmount()   -- mailbox badge slot
Core.Client.onMailbox(fn(count)) -> Connection; Core.Client.state().mailbox / .odds
```

## Modules

Core is a **foundation** plus **optional modules**. The foundation is always on: Data, Net, Shop,
Analytics, Policy, Events, Console, Replication on the server; the UI kit, Feedback, Input and Hud
on the client. A game switches modules on in `GameConfig.modules`:

| Module | Requires | Optional integrations | Config section it needs |
|---|---|---|---|
| Items | – | – | `items` |
| Inventory | Items | Plot, Upgrades, Mail (`sendGift`) | `balance.inventory` |
| Rarity | Items | Inventory (grants), Economy (`cost`) | `balance.rarityTables` |
| Economy | – | Items, Rebirth, Upgrades, Friends | `balance.income` |
| Upgrades | Economy | Rebirth | `balance.upgrades` |
| Rebirth | Economy | Inventory, Upgrades, Plot, Items | `balance.rebirth` |
| Offline | – | Economy (`autoPay`) | `balance.offline` |
| Streak | – | Economy (`rewards`) | `balance.streak` |
| Friends | – | Economy (`coPlayMultiplier`) | `balance.friends` |
| Mail | – | – | `mail` (optional tuning) |
| Plot | Inventory | Items | `balance.plot` (optional) |

`packages/core/shared/Modules.luau` is the source of truth (requires, optional, public API names).

```lua
-- games/<name>/src/shared/Config/init.luau
local Config: Types.GameConfig = {
	gameId = "example-shop",
	-- Foundation is implicit. List only what the game uses; dependencies must be listed too.
	modules = { "Items", "Inventory", "Rarity", "Plot", "Economy", "Offline", "Friends" },
	items = require(script.Items),
	balance = require(script.Balance), -- needs income/inventory/rarityTables/offline/friends
	...
}
-- foundation only: modules = {} (items = {}, and no module sections are needed)
```

- `Core.start` fails with a clear error for an unknown module name, a foundation name, a duplicate
  or a missing dependency (`module 'Rebirth' requires 'Economy': add "Economy" ...`), and when a
  config feature needs a module that is off (e.g. `balance.offline.autoPay` without Economy).
- Disabled modules still exist on the facade, but every call errors:
  `Rebirth is not enabled in GameConfig.modules`. Client Actions of a disabled module error too.
- Inside core: `ctx.isEnabled(name)` guards every OPTIONAL dependency; a disabled module in
  `ctx.services` is a proxy that errors the same way.

## API rules (core-contract-v1.2)

- **Frozen facade.** `Core.<Namespace>` is a frozen table with exactly the functions of
  `Types.<Namespace>API` (listed in `Modules.API`). No `init`/`start`, no private helpers. A second
  `Core.start` errors; calling a server API before `Core.start` errors.
- **Services never write another module's PlayerData sections** and never require another
  service's private modules. Cross-module work goes through public functions, the ctx-only
  `*Internal` functions in `Context.luau`, or Rebirth reset steps (`addResetStep`).
- **`Data.update(player, fn)`**: fn runs on a working copy and commits only if it returns without
  error (an error discards every write); fn must not yield; a nested `Data.update` for the same
  player errors. To combine several changes atomically use a transaction (`server/Tx.luau`) and
  the `*Into` functions (`Economy.grantInto`, `Inventory.addInto`, `Rarity.rollInto`).
- **Purchases (receipt-safe).** A product handler is data-only:
  ```lua
  Core.Shop.onProduct("EggRoll", function(data, receipt, tx)
  	if not tx.policyKnown then tx.retryLater("policy_unknown") end -- NotProcessedYet, nothing saved
  	if tx.paidRandomRestricted then assert(tx.addItem("crystal")) return end -- fixed fallback
  	local def, info = tx.roll("Egg")          -- paid roll granted into `data`
  	assert(def and info.ok, info.reason)      -- error = nothing granted, nothing recorded
  end)
  ```
  The grant and `purchases[PurchaseId]` are one non-yielding `Data.update`; `PurchaseGranted` is
  returned only after the save is confirmed. Never call `Economy.grant`/`Inventory.add` from a
  handler (nested update error); use `tx.grant/addItem/roll` or write `data.game[gameId]`.
- **Mail is at-least-once.** Handlers must be safe to run twice; pass an idempotency `key` to
  `Mail.send` when a retry of the send could duplicate a message. Handler result: `nil`/`true` =
  delivered, `false` = held in the mailbox (capacity, never a failure), error = retried with
  backoff (`GameConfig.mail`), then dead-lettered.
- **Gifts:** `Inventory.transfer` (both players in this server) or `Inventory.sendGift` (any
  user, through Mail). Copies from paid random sources (`paid:`/`paidcur:`) can't be mailed.
- **Rebirth keeps Robux-bought items** (`source` starting with `paid:`) unless
  `ItemDef.keepOnRebirth = false`; `keepOnRebirth = true` keeps any copy. Rolls priced in a paid
  currency are tagged `paidcur:` (policy/trade rules apply, but rebirth wipes them).
- **Luck on paid rolls:** see hard rule 11 (core errors otherwise).
- **Odds shown to players come from the server** (`ReplicatedState.odds`, `Rarity.getOddsDetail`),
  including mutations and pity. Never recompute odds on the client.
- **Admins are server-only**: `ServerConfig.admins`, kept in `ServerScriptService`/`ServerStorage`.

## Server console (Studio / admin)

`game.ServerScriptService.CoreServer.CoreConsole:Invoke("help")` from the Studio command bar
(Server context during Play) lists commands services registered with `ctx.console.register`.

## How games use core

- `src/shared/Config/init.luau` returns a `Types.GameConfig` (Items, Balance, Products, Events,
  Palette files). It must pass `ConfigValidate` (`tools/test` checks the sandbox config).
- `src/server/ServerConfig.luau` (ServerScriptService.Game.ServerConfig) returns a
  `Types.ServerConfig` (`admins`). It never reaches clients.
- `src/server/Main.server.luau` builds/loads the world, calls `Core.start(Config, ServerConfig)`,
  then wires the game's unique system to core (`Core.Rarity.roll`, `Core.Inventory.add`, `Core.Offline.onReturn`, ...).
- `src/client/Main.client.luau` calls `Core.start(Config)`, mounts the HUD, reads `Core.Client.state`
  and sends requests with `Core.Client.Actions`.
- A game's own remotes: `src/shared/net/game.blink` with `option RemoteScope = "<GAMEID>"`, compiled
  by `tools/net`. On the server register each client event with
  `Core.Net.handle("PlaceItem", GameNet.PlaceItem, Tuning.limits.placeItem, fn)` (rate limit,
  left-player drop, pcall) and validate every argument in `fn`.
- Plots: ship Models tagged `CorePlot` with BasePart slots that have a string `SlotId` attribute.
  Optional: `SlotTag` on a slot (only items with that tag), `PlotOrder` on the plot, a part named
  `Spawn` (or `PlotSpawn = true`) for the owner's spawn. Core writes `OwnerUserId`; don't set it.
  Item models live in `ReplicatedStorage.GameAssets` (or `GameConfig.assetsFolderName`) by
  `ItemDef.model`. Full table: `packages/core/server/Plot/README.md`.
- UI: render screens inside `UI.ScaledRoot`; read `packages/ui/README.md` (mobile checklist).
- Studio test hooks: `game.ServerScriptService.CoreServer.CoreConsole:Invoke("help")`.

## How to add a core service (core owner only)

1. Add its API type to `Types.luau` (additive) and its field to `CoreAPI`/`ServerServices`.
2. Add it to `Modules.luau`: `API` (public function names), and for an optional module `SPECS`
   (requires/optional), `MODULE_ORDER` and the `ModuleName` type.
3. Create `packages/core/server/<Name>/init.luau` with `init(ctx)`, `start()` and the API functions.
   `init` stores ctx only (no cross-service calls, no yields); `start` connects events. Guard
   optional dependencies with `ctx.isEnabled`.
4. Register it in `packages/core/server/init.luau` (`services`).
5. Client requests: add an event to `core.blink`, run `tools/net`, add a rate limit in
   `core/server/Net/init.luau`, register exactly one handler with `ctx.net.handle(name, fn)`.
6. Pure logic goes in zero-dependency modules (numbers in, numbers out) with `*.spec.luau` tests.
7. CHANGELOG entry, README in the service folder, run the commands below.

Services talk to each other only through `ctx.services.<Name>.<public function>`.

## Commands (from the repo root)

```sh
tools/install                 # rokit install + wally install (deps/)
tools/lint                    # selene + stylua --check
tools/test                    # Lune specs (*.spec.luau)
tools/typecheck [game]        # luau-lsp strict type check with Roblox definitions
tools/net                     # regenerate Blink code after editing a .blink file
rojo build games/_sandbox/default.project.json -o /tmp/sandbox.rbxl
rojo serve games/_sandbox/default.project.json   # port 34872, connect the Studio Rojo plugin
tools/install --hooks-only    # enable .githooks/pre-commit (lint + tests) for this clone
tools/test-sim [--pending]    # multi-server simulation incl. the slow soak test
tools/doctor                  # toolchain, Wally packages, hook, .env keys (never values), ports
tools/dev <name>              # rojo serve on the game's port + Studio connect steps
tools/new-game <name> [--modules A,B,C] [--no-design-doc]   # scaffold from templates/new-game
tools/core-status             # every game's core version and test/live sync with HEAD
tools/publish <name> --test|--live [--dry-run]   # build + Open Cloud upload (ask the user first)
```

## Publish flow (docs/publishing.md has the one-time setup)

1. The user creates the Group, a test and a live experience per game, and an Open Cloud key with
   only `universe-places:write` for those experiences, in the git-ignored `.env`
   (`ROBLOX_OPEN_CLOUD_API_KEY`). Agents never create keys or upload without the user's OK.
2. Put the universe/place ids in `games/<name>/deploy.json` (placeholders are 0; publish refuses them).
3. `tools/publish <name> --test --dry-run`, then (with the user's OK) `tools/publish <name> --test`:
   lint, tests, typecheck, build, upload, stamp `deploy.json` + GAMES.md with the core version.
4. Playtest the test place (`docs/manual-qa.md`).
5. `tools/publish <name> --live`: refused unless the same build was published to `--test` first
   and the tree is clean; asks for the game name to confirm. Commit the stamped files.

## Definition of done

- Behaviour implemented for real (no stub left in your scope), server-authoritative, config-driven.
- Pure logic has `*.spec.luau` tests; `tools/test` passes.
- `tools/lint` clean; `tools/typecheck` clean for your files.
- `rojo build games/_sandbox/default.project.json -o /tmp/sandbox.rbxl` succeeds.
- A short `README.md` in your service folder (what it does, config keys, signals, gotchas).
- Interface unchanged unless the core owner approved an additive change (CHANGELOG updated).
- Report: what you built, files touched, test output, open questions.
