# CLAUDE.md — rules for every agent in this repo

Roblox multi-game monorepo built on **StudWork**, an opinionated framework: a small foundation
(`packages/framework`), optional kit modules (`packages/kits`), a UI kit (`packages/ui`), and many games
(`games/<name>`), each published as its own Roblox experience. Language: **Luau, `--!strict`**.
Read `docs/philosophy.md` (why it is opinionated), `docs/framework/` (how to use it; start with
`getting-started.md`) and `docs/decisions.md` (why things are the way they are).
`docs/framework/module-api.md` is the source of truth for the module API.

## Hard rules

1. **Games never edit `packages/`** (framework, kits, ui, vendor). Game work happens on a `game/<name>`
   branch; the `packages` guardrail refuses package edits there. Need something? Add an entry to
   `CORE_REQUESTS.md`. Only the core owner changes packages.
2. **The module API is additive only.** `docs/framework/module-api.md`, `packages/framework/shared/`
   (the `StudWork` facade and `Types.luau`) and `framework.blink` gain things; nothing is renamed or
   removed. Mark old calls `-- @deprecated <replacement>` and keep them working. Record every change in
   `packages/framework/CHANGELOG.md`; module-api.md additions go in §19+ marked `(added in ...)`.
   (core-v1.3.0 was the last round allowed to break things; listed under "Breaking".)
3. **The server is authoritative.** Clients only send requests (module actions, §9). The server validates
   every argument (type, range, ownership) and every action is rate-limited by the framework's Net. Never
   trust amounts, item ids, uids, prices or positions from a client. Robux purchases go through
   `ctx.shop.onProduct` (receipt-safe, data-only handlers, see "Purchases"), never through a remote.
4. **Every balance number lives in the game's Config** (`games/<name>/src/shared/Config`): kit settings
   in `config.<Module>` (`Balance.luau`), game-own numbers in `Tuning.luau`. Modules read their config
   from `ctx.config`; kits ship opinionated defaults, documented on each kit page.
5. **No secrets in the repo.** Open Cloud keys come from env vars or the git-ignored `.env`.
6. **Look before you use** a library: check it is maintained, confirm version and install method, pin
   exact versions (`=x.y.z` in `deps/wally.toml`, `@x.y.z` in `rokit.toml`), record the choice in
   `docs/decisions.md`. Not on Wally → vendor into `packages/vendor/<name>/` with its LICENSE and a
   SOURCE.md (url, commit/version, why).
7. **Git:** feature branches + worktrees, local commits only. Never push, never add remotes. Commit only
   your own paths (no `git add -A` in shared trees).
8. **Paid random items** (Compliance, module-api §14 and §19.6–19.7):
   - Odds are always disclosed: every random source registers with `ctx.compliance`; players see the
     server's odds (mutations, pity, luck) in the odds UI. Never recompute odds on the client.
   - Paid rolls go only through `ctx.compliance.roll` (inside a purchase) or
     `ctx.compliance.spendForRoll` (priced in a currency listed in `compliance.paidCurrencies`). A paid
     currency spent on a non-random good goes through `ctx.compliance.spendPaid`; any roll later in that
     tx counts as paid. `Economy.spend` refuses paid currencies.
   - A paid roll needs the source's odds already sent to that player's client (a purchase without them
     is retried). Luck other than 1 on a paid roll is refused unless the table has `luckDisclosed = true`
     and the client received odds computed with that exact luck. Give luck with `Rarity.setLuck`, never
     as a hidden roll argument. Free rolls may use any luck.
   - Players restricted by `PolicyService` can't buy paid random items: a Robux product handler grants a
     fixed non-random fallback (`tx.paidRandomRestricted`), never takes money for nothing. Copies from
     paid sources are tagged by the framework (`paid:<product>`, `paidcur:<table>`); tags can't be forged
     and those copies can't be traded or mailed.
9. **No text-chat dependence** (chat is age-gated): pings, emotes, roles.
10. **Ask the user** before installing anything outside the repo or with sudo, spending money, publishing
    to Roblox, or touching files outside the repo root.
11. **Nothing is special.** Kits, examples and game modules use only the `StudWork` facade, their `ctx`,
    the UI kit and other modules' public APIs (`StudWork.use(ref)` / `ctx.deps[ref]`). Never require
    framework internals (`ServerScriptService.Framework`), never read or write another module's save
    section, never walk the framework's instances. The `special` guardrail enforces it.
12. **Network only through the framework.** Declare a module's actions/events (§9); never use
    `OnServerEvent`/`OnServerInvoke`, `RemoteEvent`/`RemoteFunction` instances, `ProcessReceipt`,
    `Prompt*PurchaseFinished`, `DataStoreService` or ProfileStore directly. The framework owns
    `ProcessReceipt` exclusively (§7.1).
13. **Full inventory is not a failure.** A Mail handler that can't accept a message now returns `false`:
    the message waits in the player's mailbox (HUD badge, Mailbox screen) with no time limit. Only
    thrown errors are retried and dead-lettered. Gifts are capped per recipient (100 undelivered) and
    return to the sender after 14 days. Handlers must be safe to run twice.
14. **Items are declared in `GameConfig.items`**, validated once at boot. Registering items after
    `StudWork.start` errors (so nothing enters a paid table before its odds are disclosed).
15. **`tools/lint` guardrails must stay clean** (`tools/lune/guardrails.luau`, `docs/framework/guardrails.md`):
    `modules`, `numbers`, `remotes`, `purchases`, `packages`, `special`, `theme`. They scan every file
    Rojo syncs. `-- guard: allow <check>` on a line is a last resort and needs a reason on the line above.

## Folder map

```
packages/framework/shared/  ReplicatedStorage.Framework        the StudWork facade (init.luau), Types,
                                                               defineModule, Theme, framework.blink
packages/framework/server/  ServerScriptService.Framework      boot + module loader, Data (sections,
                                                               migrations, Tx), Net, Shop, Compliance,
                                                               Policy, Analytics, Events, Replication,
                                                               Console (internal: never require it)
packages/framework/client/  ReplicatedStorage.FrameworkClient  client boot, state, Feedback, Input, Hud
packages/framework/test/    (not in the place)                 Lune harness, specs, sim/ (multi-server)
packages/kits/<kit>/        shared -> ReplicatedStorage.Kits.<Kit>, server -> ServerScriptService.Kits.<Kit>
                            collection: Items Rarity Inventory    economy: Economy Upgrades Rebirth Offline
                            base: Plot    social: Friends Mail    engagement: Streak
packages/ui/                ReplicatedStorage.UI               React-lua component kit (theme-driven)
packages/vendor/            ServerStorage.Vendor               vendored libraries
deps/                       wally.toml; Packages -> ReplicatedStorage.Packages,
                            ServerPackages -> ServerStorage.ServerPackages
games/<name>/               default.project.json, deploy.json, README.md
  src/shared/Config/        ReplicatedStorage.Game.Config      init (GameConfig), Balance, Items,
                                                               Products, Events, Palette, Tuning
  src/server/               ServerScriptService.Game           Main.server.luau (world + StudWork.start),
                                                               ServerConfig (admins; never reaches clients)
  src/client/               StarterPlayerScripts.Game          Main.client.luau
  modules/<gameId>/         module.luau -> ReplicatedStorage.GameModule.module,
                            server/ -> ServerScriptService.Modules.<Name>   the game's own module
examples/modules/           third-party-style modules (e.g. leaderboard)
templates/                  copied by tools/new-game, make-module, make-screen, make-migration
tools/                      see Commands
docs/                       philosophy.md, framework/, decisions.md, known-issues.md, games/<name>.md
```

## The API (summary — `docs/framework/module-api.md` is the source of truth)

```lua
local StudWork = require(ReplicatedStorage.Framework)
StudWork.start(Config, ServerConfig)       -- server, once (a second call errors)
StudWork.start(Config)                     -- client, once
StudWork.use(ModuleRef) -> API             -- frozen public API; a module not in GameConfig.modules errors
StudWork.defineModule({ name, version, framework = "^1.3.0", dependsOn, optional, data, config,
                        itemFields, theme, server = "<Folder>", client = ... }) -> ModuleRef
StudWork.Client.state()                    -- Charm atom of the local player's replicated state
StudWork.test                              -- harness / purchase / memoryStore / sim for specs
```

A module's server part gets `ctx` (§5): `config`, `deps[ref]`, `depsTx`, `depsExt`, `isEnabled`, `data`
(its own section only), `tx(player, fn)` + `section(tx)` for atomic multi-module changes, `framework`
(read-only facts), `net`, `replicate`, `compliance`, `policy`, `analytics`, `events`, `shop`, `signals`,
`console` (commands auto-prefixed), `lifecycle`, `log`, `theme`, `now()`, `serverConfig`.

## Override levels (`docs/framework/override-levels.md`)

Go only as deep as you need:
1. **Use the defaults:** list kit modules in `GameConfig.modules`.
2. **Change config:** `config.<Module>` in `Balance.luau`, `GameConfig.theme`.
3. **Replace a piece:** your own rarity preset, theme, HUD widget (`client.hud.widgets`,
   `UI.registerWidget`), whole HUD (`client.hud`) or screen (`UI.registerScreen`).
4. **Switch a kit off:** leave it out of `modules` (`tools/new-game --modules`). Disabled modules keep
   their save sections; calls to them error clearly.
5. **Write your own module:** `tools/make-module`; the same public API the kits use.

## Data and purchases

- **One save section per module** (`data = { key, version, default, migrations, replicate, sanitize }`).
  `ctx.data` reaches only that section. Migrations are numbered with no gaps (a gap is a boot error);
  v1.2 saves migrate automatically. A failed load never writes; a stolen session stops all writes.
- **Transactions:** `ctx.tx(player, function(tx) ... end)` runs on a working copy and commits only if it
  returns without error (an error discards every write); it must not yield. Use `depsTx` (e.g.
  `Economy.grantInto`, `Inventory.addInto`) to combine modules atomically. Committed data is frozen:
  never keep a `section(tx)` reference past the tx.
- **Purchases (receipt-safe).** A product handler is data-only:
  ```lua
  ctx.shop.onProduct("EggRoll", function(data, receipt, tx)
  	if not tx.policyKnown then tx.retryLater("policy_unknown") end -- NotProcessedYet, nothing saved
  	if tx.paidRandomRestricted then assert(tx.addItem("crystal")) return end -- fixed fallback
  	local def, info = tx.roll("Egg")          -- paid roll, granted in the same commit
  	assert(def and info.ok, info.reason)      -- error = nothing granted, nothing recorded
  end)
  ```
  The grant and the receipt record are one commit; `PurchaseGranted` is returned only after the save
  is confirmed. Side effects (sounds, analytics) go in `tx.after`.
- **Rebirth keeps Robux-bought copies** (`paid:`), always; `paidcur:` and earned copies are wiped unless
  `keepOnRebirth = true`.
- **Admins are server-only:** `ServerConfig.admins`.

## Server console (Studio / admin)

`game.ServerScriptService.Framework.StudWorkConsole:Invoke("help")` from the Studio command bar
(Server context during Play). Commands are module-prefixed: `economy grant 100 Coins <userId>`,
`rarity roll Block <userId>`, `shop receipt EggRoll <purchaseId> <userId>`, `data dump <userId>`.

## How games use StudWork

- `src/shared/Config/init.luau` returns a GameConfig (`gameId`, `modules = { require(<kit module>) ... }`,
  `items`, `config` per module, `products`, `theme`, `client.hud`, `compliance.paidCurrencies`).
  Unknown config and theme keys are boot warnings, so typos show up.
- `src/server/Main.server.luau` builds the world and calls `StudWork.start(Config, ServerConfig)`.
  Gameplay lives in the game's own module (`modules/<gameId>/`), which the framework adds by itself;
  its save section is the gameId.
- `src/client/Main.client.luau` calls `StudWork.start(Config)`; read state with `StudWork.Client.state()`.
- Plots: Models tagged `CorePlot` with BasePart slots carrying a string `SlotId` attribute (see the Plot
  kit page). Item models live in `ReplicatedStorage.GameAssets`.
- UI: render inside `UI.ScaledRoot`, use theme tokens (no colour/asset literals: `theme` guardrail),
  `docs/framework/theme.md`, `packages/ui/README.md` (mobile checklist).

## Changing the framework (core owner only)

Games and game agents never do this (hard rule 1): they file a `CORE_REQUESTS.md` entry. For the core
owner, every change to the module API is **additive** (hard rule 2):

1. **Design it in `docs/framework/module-api.md` first**, as a new numbered subsection at the end of §19
   (or a later section), titled `(added in <version>: <why>)`. Never edit earlier sections' meaning;
   point to the addition from them if needed.
2. **Types:** add the new fields/functions to `packages/framework/shared/Types.luau` (and the `ctx` type
   if it is a ctx service). Optional fields only; no renames, no removals, no narrowed types.
3. **Network:** new framework events go in `packages/framework/shared/net/framework.blink`; run
   `tools/net`, add the rate limit in `packages/framework/server/Net/init.luau`, validate every argument
   on the server. Modules declare their own actions (§9) instead whenever they can.
4. **Implement it through the public surface:** kits must be able to use it exactly as a third-party
   module would (no kit-only tokens or internal requires: the `special` guardrail checks this).
5. **Tests:** a `*.spec.luau` for the new behaviour, written against `StudWork.test`, that fails without
   the change; a guardrail self-test if it adds or changes a lint rule; `tools/test-sim` if it touches
   data, purchases or cross-server behaviour. Never weaken an existing assertion.
6. **Docs:** the user-facing page (`docs/framework/*.md` or the kit page under `docs/framework/kits/`)
   and the folder README; an entry in `packages/framework/CHANGELOG.md`; the reason in `docs/decisions.md`.
7. **Check:** `tools/lint`, `tools/typecheck` for every game, `tools/test`, `tools/test-sim`, a rojo build
   of every game, and `tools/bench` if it runs per tick or per player (≤ +20% vs the last release).

## Commands (from the repo root)

```sh
tools/install                 # rokit install + wally install (deps/); --hooks-only enables the pre-commit hook
tools/doctor                  # toolchain, Wally packages, hook, .env keys (never values), ports
tools/lint                    # selene + stylua --check + guardrails
tools/typecheck [game]        # luau-lsp strict type check with Roblox definitions
tools/test                    # Lune specs (*.spec.luau)
tools/test-sim [--pending]    # multi-server simulation incl. the slow soak test
tools/bench                   # server tick cost at 50 players
tools/net                     # regenerate Blink code after editing a .blink file
tools/new-game <name> [--modules A,B,C] [--no-design-doc]
tools/make-module <Name> / tools/make-screen <Name> / tools/make-migration <module>
tools/dev <name>              # rojo serve on the game's port + Studio connect steps
tools/core-status             # every game's framework version and test/live sync with HEAD
tools/publish <name> --test|--live [--dry-run]   # ask the user first
rojo build games/_sandbox/default.project.json -o /tmp/sandbox.rbxl
```

## Publish flow (docs/publishing.md has the one-time setup)

1. The user creates the Group, a test and a live experience per game, and an Open Cloud key with only
   `universe-places:write` for those experiences, in the git-ignored `.env` (`ROBLOX_OPEN_CLOUD_API_KEY`).
   Agents never create keys or upload without the user's OK.
2. Put the universe/place ids in `games/<name>/deploy.json` (placeholders are 0; publish refuses them).
3. `tools/publish <name> --test --dry-run`, then (with the user's OK) `tools/publish <name> --test`.
4. Playtest the test place (`docs/manual-qa.md`).
5. `tools/publish <name> --live`: refused unless the same build went to `--test` first and the tree is
   clean; asks for the game name to confirm. Commit the stamped files.

## Definition of done

- Behaviour implemented for real (no stub left in your scope), server-authoritative, config-driven.
- Pure logic has `*.spec.luau` tests (`StudWork.test` for module tests); `tools/test` passes.
- `tools/lint` clean; `tools/typecheck` clean for your game.
- `rojo build games/<name>/default.project.json -o /tmp/<name>.rbxl` succeeds.
- Module API unchanged unless the core owner approved an additive change (CHANGELOG updated).
- Report: what you built, files touched, test output, open questions.
