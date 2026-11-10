# CLAUDE.md — rules for every agent in this repo

Roblox multi-game monorepo. One shared core (`packages/core`, `packages/ui`), many games
(`games/<name>`), each published as its own Roblox experience. Language: **Luau, `--!strict`**.
Read `docs/decisions.md` for why things are the way they are.

## Hard rules

1. **Games never edit `packages/core` or `packages/ui`.** Need something? Add an entry to
   `CORE_REQUESTS.md`. Only the core owner changes core.
2. **Core's interface is additive only.** `packages/core/shared/Types.luau` and
   `packages/core/shared/net/core.blink` gain things; nothing is renamed or removed. Mark old calls
   `-- @deprecated <replacement>` and keep them working. Record every change in
   `packages/core/CHANGELOG.md`.
3. **The server is authoritative.** Clients only send requests. The server validates every argument
   (type, range, ownership) and every remote is rate-limited (`core/server/Net`). Never trust
   amounts, item ids, uids, prices or positions from a client. Robux purchases go through
   `Shop.onProduct`, never through a remote.
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
   trade items from paid random sources.
9. **No text-chat dependence** (chat is age-gated): pings, emotes, roles.
10. **Ask the user** before installing anything outside the repo or with sudo, spending money,
    publishing to Roblox, or touching files outside the repo root.

## Folder map

```
packages/core/shared/   ReplicatedStorage.Core        facade (init.luau), Types, Palette, RarityTiers,
                                                      Sounds, Validate, ConfigValidate, Signals,
                                                      HandlerList, PlotLayout/, net/core.blink
packages/core/server/   ServerScriptService.CoreServer bootstrap (init.luau), Context, Net/ (Blink +
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
Core.start(Config)                                   -- once on the server, once on the client
-- server
Core.Items.register(defs) / .get(id) / .all() / .byTag(tag) / .incomeOf(instance)
Core.Rarity.roll(tableId, player, luck?, { paid?, grant?, reason? }) -> (ItemDef?, RollInfo)
Core.Rarity.getOdds(tableId, luck?) -> { [itemId]: probability } / .tiers()
Core.Economy.grant/spend(player, amount, reason, currency?) -> boolean / .balance(player, currency?)
Core.Economy.addIncomeSource/removeIncomeSource(player, sourceId, perSec)
Core.Economy.addMultiplier(player, id, mult, expiresAt?, persist?) / .removeMultiplier / .getMultiplier / .getRate
Core.Inventory.add(player, itemId, opts?) -> ItemInstance? / .remove / .get / .list / .count / .cap
Core.Inventory.transfer(from, to, uid, reason) -> (ok, err?) / .canTrade(player)
Core.Plot.get(player) -> Model? / .owner(plot) / .display(player, uid, slotId?) / .clearDisplay / .slots / .onAssigned
Core.Upgrades.level/cost/purchase(player, upgradeId)
Core.Rebirth.canRebirth/rebirth/cost/multiplier(player)
Core.Offline.onReturn(fn(player, secondsAway))        Core.Streak.onDaily(fn(player, day)) / .get
Core.Friends.onCoPlay(fn(player, friends, "server"|"invite"|"private")) / .friendsInServer
Core.Events.schedule(id, schedule?, fn(ctx)) / .trigger(id, by?) / .isActive / .onEnded
Core.Shop.onProduct(product, fn(player, receipt) -> granted) / .ownsPass / .onPassOwned
Core.Policy.paidRandomRestricted(player)
Core.Data.get / .update(player, fn) / .onLoaded / .isLoaded / .getGame / .updateGame / .saveAsync
Core.Mail.send(userId, kind, payload) / .onReceive(kind, fn)
Core.Analytics.funnel(player, step) / .economy(player, flow, currency, amount, type, sku?) / .custom
Core.Signals.DataLoaded, DataChanged, CurrencyChanged, ItemAdded, ItemRemoved, ItemDisplayed, ...
-- client
Core.Client.state()                                   -- Charm atom: ReplicatedState of the local player
Core.Client.Feedback.pop(text, position?, rarity?) / .flash(rarity) / .sound(key) / .shake(intensity?)
Core.Client.Input.device() / .deviceChanged / .bind(actionId, binding, fn) / .unbind
Core.Client.Actions.display/clearDisplay/rebirth/upgrade/roll/gift/triggerEvent/funnel
Core.Client.Hud.mount({ nextGoal = fn }) / .unmount()
```

## Server console (Studio / admin)

`game.ServerScriptService.CoreServer.CoreConsole:Invoke("help")` from the Studio command bar
(Server context during Play) lists commands services registered with `ctx.console.register`.

## How games use core

- `src/shared/Config/init.luau` returns a `Types.GameConfig` (Items, Balance, Products, Events,
  Palette files). It must pass `ConfigValidate` (`tools/test` checks the sandbox config).
- `src/server/Main.server.luau` builds/loads the world, calls `Core.start(Config)`, then wires the
  game's unique system to core (`Core.Rarity.roll`, `Core.Inventory.add`, `Core.Offline.onReturn`, ...).
- `src/client/Main.client.luau` calls `Core.start(Config)`, mounts the HUD, reads `Core.Client.state`
  and sends requests with `Core.Client.Actions`.
- A game's own remotes: `src/shared/net/game.blink` with `option RemoteScope = "<GAMEID>"`, compiled
  by `tools/net`. Validate and rate-limit them the same way core does.
- Plots: ship Models tagged `CorePlot` with BasePart slots that have a string `SlotId` attribute.

## How to add a core service (core owner only)

1. Add its API type to `Types.luau` (additive) and its field to `CoreAPI`/`ServerServices`.
2. Create `packages/core/server/<Name>/init.luau` with `init(ctx)`, `start()` and the API functions.
   `init` stores ctx only (no cross-service calls, no yields); `start` connects events.
3. Register it in `packages/core/server/init.luau` (`services` + `ORDER`) and in the facade's
   `SERVER_ONLY` list.
4. Client requests: add an event to `core.blink`, run `tools/net`, add a rate limit in
   `core/server/Net/init.luau`, register exactly one handler with `ctx.net.handle(name, fn)`.
5. Pure logic goes in zero-dependency modules (numbers in, numbers out) with `*.spec.luau` tests.
6. CHANGELOG entry, README in the service folder, run the commands below.

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
tools/new-game <name>         # scaffold games/<name> from templates/new-game
tools/publish <name> --test|--live [--dry-run]   # build + Open Cloud upload (ask the user first)
```

## Definition of done

- Behaviour implemented for real (no stub left in your scope), server-authoritative, config-driven.
- Pure logic has `*.spec.luau` tests; `tools/test` passes.
- `tools/lint` clean; `tools/typecheck` clean for your files.
- `rojo build games/_sandbox/default.project.json -o /tmp/sandbox.rbxl` succeeds.
- A short `README.md` in your service folder (what it does, config keys, signals, gotchas).
- Interface unchanged unless the core owner approved an additive change (CHANGELOG updated).
- Report: what you built, files touched, test output, open questions.
