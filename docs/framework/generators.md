# Generators

All generators are Lune scripts behind `tools/*` wrappers; run them from the repo root. Each has a
self-test that generates into a scratch folder, checks the output and cleans up
(`tools/test tools/lune`).

## tools/new-project

```
tools/new-project <path> [--name <gameId>] [--modules A,B,C] [--url <studwork-url>] [--tag vX.Y.Z]
                  [--no-install] [--author-name <name>] [--author-email <email>]
```

`tools/new-project --help` (or `-h`; also on `tools/new-game`) prints every option and exits 0.

(v1.5.0) A complete single-game project at `<path>`: git repo, StudWork as the `studwork/`
submodule at a tag, the game at the root (`tools/new-game`'s template, `$path`s into `studwork/`,
`docs/design.md`), the skeleton from `templates/single-game/`, `tools/install`, and the first
commit through the hook. Details: [single-game-project.md](single-game-project.md).

## tools/new-game

```
tools/new-game <name> [--modules A,B,C] [--no-design-doc] [--into <folder>]
```

Copies `templates/new-game` to `games/<name>` (or `<folder>/<name>` with `--into`; the
framework's override examples use `--into examples/overrides`), picks the next free Rojo port, writes
`deploy.json` with placeholder ids, sets `gameId`, renames the game's own module (`modules/<name>`,
module name in PascalCase: `my-game` -> `MyGame`), rewrites every project `$path` that leaves the
template for the game's depth (in a games repo: into `roblox-core/`, see
[games-repo.md](games-repo.md)), adds a `GAMES.md` row when the project has a `GAMES.md`, and
(unless `--no-design-doc`) creates `docs/games/<name>.md` from `templates/game-design.md`.

`--modules` writes code and config for the listed modules only, so `tools/lint` passes with no
hand trimming:

- `GameConfig.modules` and the game module's `dependsOn`: (v1.7.1) every kit named in `--modules`
  goes in `dependsOn`: the four the template lists as `optional` move there, and a named kit the
  template doesn't refer to (e.g. `Items`) gets a ref line in the same style (a kit only added as a
  dependency of another keeps the template's place);
- the game module's server code (product handlers, events, console commands, signal hooks);
- `Balance.luau` sections, and values that depend on another module (`income.source` is
  `"displayed"` only with Plot, `"owned"` otherwise; Streak rewards and the Friends multiplier only
  with Economy);
- Items fields (`economy = { incomePerSec }` only with Economy), products, events, tuning;
- (v1.7.0) the `Leaderboards`, `Badges`, `Notifications` and `TextFilter` config sections in `Balance.luau`, and their `optional` entries in the game module (a trimmed `--modules` list drops both, and moves a named one to `dependsOn`), so a game made with `--modules` lists no module it doesn't use;
- the client's action bar (upgrade, chest, egg, rebirth, mailbox buttons) and the HUD goal;
- the world's plots (only with Plot).

Missing hard dependencies are added and reported. `--modules ""` = foundation only. The template
marks module-specific code with comment markers that the generator resolves and strips (syntax:
`templates/new-game/README.md`). Afterwards it runs StyLua on the game and re-runs the guardrails.

Proved for these subsets (each passed `tools/lint`, `tools/typecheck` and its boot test): none,
`Items`, `Inventory`, `Rarity`, `Items,Rarity,Inventory`, `Economy`,
`Economy,Upgrades,Rebirth,Offline`, Collection + Economy, `Friends,Mail`, `Streak`, `Plot`, each of the four v1.7.0 modules (`Leaderboards`, `Badges`, `Notifications`, `TextFilter`),
`Mail,Inventory`, and all. The game module's console help text and log tags say the module's own lower-case name (`mygame giftme`, the command a player really types: [testing.md](testing.md#console-commands)); the scaffold ships `src/server/GameModule.spec.luau`, a worked spec of the game module against the kits ([testing.md](testing.md)). The self-test (`tools/lune/NewGame.spec.luau`) resolves the template's
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
| `net.blink` (`--net`) | the module's own client <-> server events: `option RemoteScope = "STUDWORK_<NAME>"`, `Casing = Pascal`, `ServerOutput = "server/Net.luau"`, `ClientOutput = "client/Net.luau"` ; run `tools/net` to generate both `Net.luau` files, which the framework binds as the parts' `net` ([module-api.md §19.9](module-api.md#199-one-folder-per-module-the-live-part-lookups-added-in-v131)) |

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
entries are generated: don't edit them by hand. The project's
own `Modules` entries (the game module's server part, a game-local module from `make-module
--game`) are kept as written. Module folders are found by `tools/lune/ModuleDiscovery.luau`, the
same discovery the Lune testkit and the multi-server sim use.

**Environments.luau (v1.7.0).** For every project with a `deploy.json` and a
`src/shared/Config/` folder it also writes `src/shared/Config/Environments.luau` (`return { test = …,
live = … }` from the ids in `deploy.json`; placeholder `0` ids are left out, the test universe id only
when it differs from the live one), which `GameConfig.environments` requires. It fails when the test
and live place ids are equal, and `--check` (run by `tools/lint`) fails when the file is missing or
drifts from `deploy.json`. A project whose game has `src/shared/Localization` also gets a
`LocalizationService` entry mapping that folder, so the CSV there becomes the game's
LocalizationTable ([localization](kits/localization.md)).

## tools/make-migration

```
tools/make-migration <module-dir | ModuleName> [--name <label>] [--from <n>]
```

Reads `data.version` from `module.luau` and writes:

- `migrations/NNN_<label>.luau` (NNN = version + 1): `function(old) -> new`, starting as a copy;
- `tests/MigrationNNN.spec.luau`: a stub test that passes, to fill in with a real old section;
- `module.luau`: `data.version = NNN`, and `migrations = script.Parent.migrations` the first time.

Update `data.default` to the new shape yourself. A module name is looked up in every game's
`modules/` (`games/*`; in a single-game project the root's `modules/`; in the core repo also
`examples/sandbox`, `examples/overrides/*`) and `examples/modules`; a folder path
(`modules/coins`) works too.

**A referenced version** (v1.7.1). `data.version` may be a number literal (`version = 3`, bumped in
place) or a reference: a local (`local VERSION = 2` … `version = VERSION`) or a field of a module in
the module's own folder (`version = Save.VERSION` with
`local Save = require(script.Parent.shared.Save)`). A reference is read by evaluating
`module.luau` under Lune the way the game requires it (files of the module's folder load for real;
`game`, the framework and kit refs are inert stand-ins), and the one number literal it comes from
(`Save.VERSION = 2`, `VERSION = 2,` or `local VERSION = 2`: the name exactly, the literal the whole
value) is bumped, and the bumped definition is read back before anything is written. When there
isn't exactly one such literal (`version = Base.VERSION + 1`, `version = 1 + Base.VERSION`) the tool
refuses and writes nothing; run it again with
`--from <current version>` to write the migration anyway and set the new version by hand (the tool
says which value). `--from <n>` gives the current version instead of reading it (an integer from 1 to
998); use it when the definition can't be evaluated outside Roblox. It is refused when it disagrees
with a version the tool can read, or when it would leave a gap after the last migration in
`migrations/` (a gap fails the boot). Evaluating runs the module's own code (as `tools/test` does),
so don't run the tool on code you don't trust.

**The migration reaches the place.** `data.migrations = script.Parent.migrations` needs the folder
in the Rojo project. For a module inside a game (`<game>/modules/<folder>`, or `modules/<folder>` at
a single-game project's root) the tool checks the game's `*.project.json` files: a node whose
`module` is `modules/<folder>/module.luau` (`ReplicatedStorage.Modules.<Name>`, or the game
module's `ReplicatedStorage.GameModule`) gets `"migrations": { "$path": "modules/<folder>/migrations" }`
unless it has one or a `$path` already maps the whole folder. Only that entry is added, in every
project file that maps the module; keys keep their order and the file is written in the
`tools/sync-projects` style (2-space JSON), so `tools/sync-projects --check` stays clean but a
hand-formatted file is re-indented. A module that
no project file maps is refused before anything is written, with the exact entry to add. A module
outside any game (`examples/modules/<x>`, a folder outside `<game>/modules/`) gets a note to map it
in its own project.

## tools/make-screen

```
tools/make-screen <game> <ScreenName>
```

Writes `games/<game>/src/client/Screens/<ScreenName>.luau` (a React screen from UI kit parts:
`UI.Modal` with a close button, no hard-coded colours), creates `src/client/Screens/init.luau`
once (registers every screen in the folder with `UI.registerScreen` under its file name), and
adds `require(script.Parent:WaitForChild("Screens")).registerAll()` to `Main.client.luau` right
after `StudWork.start(Config)`. Open it with `UI.open("<ScreenName>")`. Registering a name a module
already uses (e.g. `Inventory`) replaces that module's screen. The registry is `UI.registerScreen`
in `packages/ui` ([module-api.md §13](module-api.md#13-theme-rarity-look-hud-and-screens)); the
generated file requires `UI` untyped (`:: any`).

## Templates

Everything the generators write comes from `templates/` in this repo:

| Folder | Used by |
|---|---|
| `templates/new-game/` | `tools/new-game` (a working game; module markers, see its README) |
| `templates/game-design.md` | `tools/new-game` (the design doc) |
| `templates/module/` | `tools/make-module` (`*.tmpl` files: `module.luau`, `server/init.luau`, `client/init.luau`, `tests/Name.spec.luau`, `README.md`, `net.blink`) |
| `templates/migration/` | `tools/make-migration` (`migration.luau.tmpl`, `Migration.spec.luau.tmpl`) |
| `templates/screen/` | `tools/make-screen` (`Screen.luau.tmpl`, `Screens.init.luau.tmpl`) |
| `templates/single-game/` | `tools/new-project` ([single-game-project.md](single-game-project.md)): the `studwork.json` marker, `tools/` wrappers, hook, `gitignore`, `env.example`, `FRAMEWORK_REQUESTS.md`, `README.md.tmpl` and `CLAUDE.md.tmpl` (`{{name}}`, `{{tag}}`, `{{port}}`, `{{modules}}`) |
| `templates/games-repo/` | copied by hand into a new games repo ([games-repo.md](games-repo.md)): `tools/` wrappers, hook, `.gitignore`, `GAMES.md`, `FRAMEWORK_REQUESTS.md` |

`{{Name}}`-style placeholders are filled by `tools/lune/MakeGen.luau`. The `.tmpl` suffix keeps
them out of lint, tests and Rojo. `tools/lune/MakeGen.spec.luau` pins the output byte for byte
(against the inline strings the generators used before the templates moved to files).

## In a games repo

Every generator also runs from a games repo that has this repo as its `roblox-core/` submodule
([games-repo.md](games-repo.md)): `tools/new-game` creates `games/<name>` with `$path`s into
`roblox-core/`, `tools/make-module --game <game>` maps the new module in that game's project, and
the templates always come from `roblox-core/templates/`.

## In a single-game project

(v1.5.0, [single-game-project.md](single-game-project.md)) The game is the project root, so no game
name is needed: `tools/make-module <Name> [--net]` writes `modules/<name-kebab>/` and maps it in the
root `default.project.json`, `tools/make-screen <Screen>` writes `src/client/Screens/<Screen>.luau`,
`tools/sync-projects` covers the root `*.project.json` files, and `tools/new-game` refuses (start
another game with `tools/new-project`). The templates come from `studwork/templates/`.
