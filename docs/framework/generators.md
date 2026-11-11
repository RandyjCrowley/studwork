# Generators

All generators are Lune scripts behind `tools/*` wrappers; run them from the repo root. Each has a
self-test that generates into a scratch folder, checks the output and cleans up
(`tools/test tools/lune`).

## tools/new-game

```
tools/new-game <name> [--modules A,B,C] [--no-design-doc] [--into <folder>]
```

Copies `templates/new-game` to `games/<name>` (or `<folder>/<name>` with `--into`, v1.4.0; the
core's override examples use `--into examples/overrides`), picks the next free Rojo port, writes
`deploy.json` with placeholder ids, sets `gameId`, renames the game's own module (`modules/<name>`,
module name in PascalCase: `my-game` -> `MyGame`), rewrites every project `$path` that leaves the
template for the game's depth (in a games repo: into `roblox-core/`, see
[games-repo.md](games-repo.md)), adds a `GAMES.md` row when the project has a `GAMES.md`, and
(unless `--no-design-doc`) creates `docs/games/<name>.md` from `templates/game-design.md`.

`--modules` writes code and config for the listed modules only, so `tools/lint` passes with no
hand trimming:

- `GameConfig.modules` and the game module's `dependsOn`;
- the game module's server code (product handlers, events, console commands, signal hooks);
- `Balance.luau` sections, and values that depend on another module (`income.source` is
  `"displayed"` only with Plot, `"owned"` otherwise; Streak rewards and the Friends multiplier only
  with Economy);
- Items fields (`economy = { incomePerSec }` only with Economy), products, events, tuning;
- the client's action bar (upgrade, chest, egg, rebirth, mailbox buttons) and the HUD goal;
- the world's plots (only with Plot).

Missing hard dependencies are added and reported. `--modules ""` = foundation only. The template
marks module-specific code with comment markers that the generator resolves and strips (syntax:
`templates/new-game/README.md`). Afterwards it runs StyLua on the game and re-runs the guardrails.

Proved for these subsets (each passed `tools/lint`, `tools/typecheck` and its boot test): none,
`Items`, `Inventory`, `Rarity`, `Items,Rarity,Inventory`, `Economy`,
`Economy,Upgrades,Rebirth,Offline`, Collection + Economy, `Friends,Mail`, `Streak`, `Plot`,
`Mail,Inventory`, and all. The self-test (`tools/lune/NewGame.spec.luau`) resolves the template's
markers for every single module, for all and for none, and checks the result compiles.

## tools/make-module

```
tools/make-module <Name> --game <game>     # games/<game>/modules/<name-kebab>/, mapped in the game's project
tools/make-module <Name> --dir <path>      # anywhere, e.g. examples/modules/<name>
tools/make-module <Name> ... --net         # also net.blink (the module's own messages)
```

Writes the module anatomy:

| File | What |
|---|---|
| `module.luau` | the definition: a config key with its default, a save section that replicates one field, server and client names |
| `server/init.luau` | `init`/`start` and an `api` through `ctx` only (counts a visit per load) |
| `client/init.luau` | a client `api` reading the replicated slice |
| `tests/<Name>.spec.luau` | a passing harness test (boot, save section, config override) |
| `README.md` | config, API and save-data tables to fill in |
| `net.blink` (`--net`) | the module's own client <-> server events: `option RemoteScope = "STUDWORK_<NAME>"`, `Casing = Pascal`, `ServerOutput = "server/Net.luau"`, `ClientOutput = "client/Net.luau"` (the core-v1.3.1 convention); run `tools/net` to generate both `Net.luau` files, which the framework binds as the parts' `net` (module-api.md §19.9) |

With `--game` it adds `ReplicatedStorage.Modules.<Name>` (`module`, `client`) and
`ServerScriptService.Modules.<Name>` to the game's `default.project.json`. It prints the
`GameConfig.modules` line to add. No `migrations/` folder until the first migration.

## tools/sync-projects

```
tools/sync-projects            # rewrite the generated module entries of every *.project.json
tools/sync-projects --check    # exit 1 on drift (tools/lint runs it)
```

Every built-in kit module (`packages/kits/<kit>/<Module>/`) is mapped in every project under
`games/`, `templates/` and `examples/` as `ReplicatedStorage.Modules.<Module>.{module, client,
shared}` and `ServerScriptService.Modules.<Module>` (the parts that exist); an example module
(`examples/modules/<x>/`) only in the projects inside its own folder (its fixture games). Those
entries are generated (core-v1.3.1, one folder per module): don't edit them by hand. The project's
own `Modules` entries (the game module's server part, a game-local module from `make-module
--game`) are kept as written. Module folders are found by `tools/lune/ModuleDiscovery.luau`, the
same discovery the Lune testkit and the multi-server sim use.

## tools/make-migration

```
tools/make-migration <module-dir | ModuleName> [--name <label>]
```

Reads `data.version` from `module.luau` and writes:

- `migrations/NNN_<label>.luau` (NNN = version + 1): `function(old) -> new`, starting as a copy;
- `tests/MigrationNNN.spec.luau`: a stub test that passes, to fill in with a real old section;
- `module.luau`: `data.version = NNN`, and `migrations = script.Parent.migrations` the first time.

For a module inside a game it also maps `migrations/` in the game's project. Update
`data.default` to the new shape yourself. A module name is looked up in every game's `modules/` (`games/*`; in the core repo also
`examples/sandbox`, `examples/overrides/*`) and `examples/modules`.

## tools/make-screen

```
tools/make-screen <game> <ScreenName>
```

Writes `games/<game>/src/client/Screens/<ScreenName>.luau` (a React screen from UI kit parts:
`UI.Modal` with a close button, no hard-coded colours), creates `src/client/Screens/init.luau`
once (registers every screen in the folder with `UI.registerScreen` under its file name), and
adds `require(script.Parent:WaitForChild("Screens")).registerAll()` to `Main.client.luau` right
after `StudWork.start(Config)`. Open it with `UI.open("<ScreenName>")`. Registering a name a module
already uses (e.g. `Inventory`) replaces that module's screen. The registry is the module-api.md
§13 contract being built in core v1.3.0 Phase 1; the generated registry calls it through an
untyped `UI` until that lands.

## Templates

Everything the generators write comes from `templates/` in the core (v1.4.0):

| Folder | Used by |
|---|---|
| `templates/new-game/` | `tools/new-game` (a working game; module markers, see its README) |
| `templates/game-design.md` | `tools/new-game` (the design doc) |
| `templates/module/` | `tools/make-module` (`*.tmpl` files: `module.luau`, `server/init.luau`, `client/init.luau`, `tests/Name.spec.luau`, `README.md`, `net.blink`) |
| `templates/migration/` | `tools/make-migration` (`migration.luau.tmpl`, `Migration.spec.luau.tmpl`) |
| `templates/screen/` | `tools/make-screen` (`Screen.luau.tmpl`, `Screens.init.luau.tmpl`) |
| `templates/games-repo/` | copied by hand into a new games repo ([games-repo.md](games-repo.md)): `tools/` wrappers, hook, `.gitignore`, `GAMES.md`, `FRAMEWORK_REQUESTS.md` |

`{{Name}}`-style placeholders are filled by `tools/lune/MakeGen.luau`. The `.tmpl` suffix keeps
them out of lint, tests and Rojo. Their output is byte-identical to the v1.3.1 generators
(`MakeGen.spec.luau` compares against v1.3.1's inline strings).

## In a games repo

Every generator also runs from a games repo that has this repo as its `roblox-core/` submodule
(v1.4.0, [games-repo.md](games-repo.md)): `tools/new-game` creates `games/<name>` with `$path`s into
`roblox-core/`, `tools/make-module --game <game>` maps the new module in that game's project, and
the templates always come from `roblox-core/templates/`.
