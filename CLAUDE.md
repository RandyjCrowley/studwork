# CLAUDE.md — rules for contributors and AI coding agents working ON the framework

This repo is **StudWork** (roblox-core), an opinionated Roblox game framework: a small foundation
(`packages/framework`), optional kit modules (`packages/kits`), a UI kit (`packages/ui`), example
games and modules (`examples/`), templates and tools. Language: **Luau, `--!strict`**.
Read `docs/philosophy.md` (why it is opinionated), `docs/framework/` (how to use it; start with
`getting-started.md`) and `docs/decisions.md` (why things are the way they are).
`docs/framework/module-api.md` is the source of truth for the module API.

Games do **not** live here. They live in a single-game project (one repo per game, made by
`tools/new-project`, with this repo as its `studwork/` git submodule:
`docs/framework/single-game-project.md`) or in a games repo that has this repo as its `roblox-core/`
git submodule (`docs/framework/games-repo.md`), pinned at a release tag. **Games and game agents
never edit this repo**; they file an entry in the games repo's `FRAMEWORK_REQUESTS.md` (or open an issue here), and the
change is made here.

## Hard rules

1. **Framework changes come through reviewed pull requests**, following "Changing the framework"
   below (see also CONTRIBUTING.md); a game never patches its copy. A games
   repo's lint refuses local edits to its `roblox-core/` submodule and an untagged submodule HEAD.
2. **The module API is additive only.** `docs/framework/module-api.md`, `packages/framework/shared/`
   (the `StudWork` facade and `Types.luau`) and `framework.blink` gain things; nothing is renamed or
   removed. Mark old calls `-- @deprecated <replacement>` and keep them working. Record every change in
   `CHANGELOG.md` (root, under `[Unreleased]`); module-api.md additions go in §19+ marked `(added in ...)`.
   (v1.3.0 was the last release allowed to break things; listed under "Breaking".) Never weaken a
   test assertion; a moved spec keeps its test count.
3. **The server is authoritative.** Clients only send requests (module actions, §9). The server validates
   every argument (type, range, ownership) and every action is rate-limited by the framework's Net. Never
   trust amounts, item ids, uids, prices or positions from a client. Robux purchases go through
   `ctx.shop.onProduct` (receipt-safe, data-only handlers), never through a remote.
4. **Network only through the framework.** Declare a module's actions/events (§9); never use
   `OnServerEvent`/`OnServerInvoke`, `RemoteEvent`/`RemoteFunction` instances, `ProcessReceipt`,
   `Prompt*PurchaseFinished`, `DataStoreService` or ProfileStore directly outside the framework's own
   Shop/Data/Store/Platform. The framework owns `ProcessReceipt` exclusively (§7.1).
5. **Every balance number lives in config.** Kits read theirs from `ctx.config` and ship opinionated
   defaults, documented on each kit page; games set them in their Config (`Balance.luau`).
6. **Paid random items** (Compliance, module-api §14 and §19.6–19.7):
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
7. **Nothing is special.** Kits, examples and game modules use only the `StudWork` facade, their `ctx`,
   the UI kit and other modules' public APIs (`StudWork.use(ref)` / `ctx.deps[ref]`). Never require
   framework internals (`ServerScriptService.Framework`), never read or write another module's save
   section, never walk the framework's instances. Framework code never names a kit. The `special`
   guardrail enforces both halves.
8. **No text-chat dependence** (chat is age-gated): pings, emotes, roles.
9. **No secrets in the repo.** Open Cloud keys come from env vars or a git-ignored `.env` (in the
   games repo). No absolute paths in committed files either.
10. **Look before you use** a library: check it is maintained, confirm version and install method, pin
    exact versions (`=x.y.z` in `deps/wally.toml`, `@x.y.z` in `rokit.toml`), record the choice in
    `docs/decisions.md`. Not on Wally → vendor into `packages/vendor/<name>/` with its LICENSE and a
    SOURCE.md (url, commit/version, why). Pins live only here: games repos use this repo's `deps/`.
11. **Git hygiene.** Feature branches; never commit to `main` directly, never `--no-verify`, never
    rewrite published history, never move or delete a release tag. Agents don't push or add remotes
    unless asked. Commit only your
    own paths (no `git add -A` in shared trees).
12. **Ask the user** before installing anything outside the repo or with sudo, spending money,
    publishing to Roblox, or touching files outside the repo root.
13. **`tools/lint` guardrails must stay clean** (`tools/lune/guardrails.luau`, `docs/framework/guardrails.md`):
    `modules`, `numbers`, `remotes`, `purchases`, `packages`, `special`, `theme`. They scan every file
    Rojo syncs. `-- guard: allow <check>` on a line is a last resort and needs a reason on the line
    above. A guardrail change needs a planted violation in its `--self-test`.

## Folder map

```
packages/framework/shared/  ReplicatedStorage.Framework        the StudWork facade (init.luau, VERSION), Types,
                                                               defineModule, Theme, framework.blink
packages/framework/server/  ServerScriptService.Framework      boot + module loader, Data (sections,
                                                               migrations, Tx), Net, Shop, Compliance,
                                                               Policy, Analytics, Events, Replication,
                                                               Console (internal: never require it)
packages/framework/client/  ReplicatedStorage.FrameworkClient  client boot, state, Feedback, Input, Hud
packages/framework/test/    (not in the place)                 Lune harness, specs, sim/ (multi-server)
packages/framework/CHANGELOG.md                                pointer to the root CHANGELOG.md
packages/kits/<kit>/<Module>/  one folder per module: module.luau -> ReplicatedStorage.Modules.<Name>.module,
                            server/ -> ServerScriptService.Modules.<Name>, client/, shared/, net.blink
                            collection: Items Rarity Inventory    economy: Economy Upgrades Rebirth Offline
                            base: Plot    social: Friends Mail TextFilter    engagement: Streak Leaderboards Badges Notifications
packages/ui/                ReplicatedStorage.UI               React-lua component kit (theme-driven)
packages/vendor/            ServerStorage.Vendor               vendored libraries
deps/                       wally.toml + wally.lock; Packages -> ReplicatedStorage.Packages,
                            ServerPackages -> ServerStorage.ServerPackages (games repos map these too)
examples/sandbox/           the reference game (every kit); foundation-only.project.json + foundation-only/
                            = the same place with modules = {}
examples/overrides/ov-a..f  one game per override case, each with src/server/Override.spec.luau
examples/modules/           third-party-style modules (session-leaderboard) with their fixture games
templates/                  new-game/ (tools/new-game), game-design.md, module/, migration/, screen/
                            (tools/make-module, make-migration, make-screen; *.tmpl), games-repo/
                            (the games-repo skeleton: tools/ wrappers, hook, .gitignore, GAMES.md),
                            single-game/ (tools/new-project's skeleton: studwork.json marker, tools/
                            wrappers, hook, gitignore, env.example, README.md.tmpl, CLAUDE.md.tmpl)
tools/                      see Commands; tools/lune/ holds the Lune side (Roots.luau: core vs games
                            repo vs single-game project)
docs/                       README.md (index), philosophy.md, framework/, decisions.md, known-issues.md,
                            manual-qa.md
.github/                    CI workflow (ci.yml), issue and pull request templates
README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md LICENSE (MIT)
wally.toml                  publish-only package manifest (not published); NEVER `wally install` at the
                            root (case-insensitive file systems: Packages/ == packages/); use tools/install
.gitattributes .editorconfig LF everywhere; tabs for Luau (stylua.toml)
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

## Changing the framework

Games and game agents never do this (hard rule 1): they file an entry in the games repo's
`FRAMEWORK_REQUESTS.md` (or an issue here). Every change to the module API is **additive** (hard
rule 2):

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
   and the folder README; an entry in `CHANGELOG.md` (root, `[Unreleased]`); the reason in `docs/decisions.md`.
7. **Check:** the definition of done below (every example game, `tools/test-games-repo`, and
   `tools/bench` if it runs per tick or per player: ≤ +20% vs the last release).

## Commands (from the repo root)

```sh
tools/install                 # rokit install + wally install (deps/); --hooks-only enables the pre-commit hook
tools/doctor                  # toolchain, Wally packages, hook, .env keys (never values), ports, layout
tools/lint                    # selene + stylua --check + sync-projects --check + guardrails
tools/typecheck [game|--all]  # luau-lsp strict (default: sandbox; --all: every example game)
tools/test [paths]            # Lune specs (*.spec.luau); with no paths also test-games-repo + test-single-game
tools/test-games-repo         # throwaway games repo with this core as its roblox-core/ submodule, tools run end to end
tools/test-single-game        # throwaway single-game project (tools/new-project, studwork/ submodule), end to end
tools/new-project <path> [--name <id>] [--modules A,B,C] [--url <u>] [--tag vX.Y.Z] [--no-install]
                              # a new single-game project (repo root = the game, this repo at studwork/)
tools/build [game|--all]      # rojo build every example game to build/
tools/test-sim [--pending]    # multi-server simulation incl. the slow soak test
tools/bench                   # server tick cost at 50 players
tools/net                     # regenerate Blink code after editing a .blink file
tools/sync-projects [--check] # regenerate the Modules entries of every *.project.json
tools/new-game <name> [--modules A,B,C] [--no-design-doc] [--into <folder>]
tools/make-module <Name> --game <g>|--dir <path> / tools/make-screen <g> <Name> / tools/make-migration <module>
tools/dev <game>              # rojo serve on the game's port + Studio connect steps
tools/core-status             # every game's framework stamp vs this core
tools/publish <game> --test|--live [--dry-run]   # games repos publish; ask the user first
mkdir -p build && rojo build examples/sandbox/default.project.json -o build/sandbox.rbxl
```

Every tool also works from a games repo and from a single-game project: their `tools/*` wrappers
(`templates/games-repo/`, `templates/single-game/`) set `STUDWORK_PROJECT_ROOT` and call
`roblox-core/tools/*` / `studwork/tools/*`; `tools/lune/Roots.luau` / `tools/_common.sh` hold the two
roots and the layout (`core`, `games-repo`, `single-game`: the committed `studwork.json` marker;
`docs/framework/games-repo.md`, `docs/framework/single-game-project.md`). Keep every tool working in
all three modes, with relative paths only; in a single-game project they need no game name.

## Definition of done (framework change)

- Behaviour implemented for real (no stub left in your scope), server-authoritative, config-driven,
  additive to the module API.
- A `*.spec.luau` that fails without the change; `tools/test` and `tools/test-sim` pass.
- `tools/lint` clean; `tools/typecheck --all` clean.
- `rojo build` of every `*.project.json` under `examples/` and `templates/` succeeds.
- `tools/new-game` still produces a working game (in a temporary worktree: lint, typecheck, test,
  rojo build) and `tools/test-games-repo` and `tools/test-single-game` pass.
- `tools/bench` within budget if it runs per tick or per player (the KITS-ALL variant is the reference: ≤ 0.94 ms/tick in v1.7.0).
- CHANGELOG, docs page, decisions entry. Report: what you built, files touched, test output, open
  questions.

## Release flow

1. Finish the change (definition of done), bump `StudWork.VERSION` in
   `packages/framework/shared/init.luau` (and `Runtime.VERSION` in the client) for the release.
2. `CHANGELOG.md` (root, Keep a Changelog): move `[Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` with
   Added / Changed / Fixed (Breaking only in a major) and add its compare link at the bottom;
   bump `version` in the root `wally.toml`; `docs/decisions.md`: why.
3. Commit, then tag the commit `vX.Y.Z` (the maintainer tags after verifying; tags never move).
4. Games repos bump their submodule to the new tag in their own commit
   (`git -C roblox-core fetch --tags && git -C roblox-core checkout vX.Y.Z`, then commit the
   pointer), run their checks, and `framework-status` shows each game against the new tag.
