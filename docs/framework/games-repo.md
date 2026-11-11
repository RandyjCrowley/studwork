# Using StudWork from a games repo

> One game per repository is simpler: `tools/new-project` makes a **single-game project** (the repo
> root is the game, StudWork at `studwork/`), see [single-game-project.md](single-game-project.md).
> This page describes the alternative layout: several games in one games repo.

StudWork lives in its own repo (this one; the docs call it "the core"). Your games live in your
own **games repo**, which has StudWork as a git submodule at `roblox-core/`, pinned at a release
tag, and runs the core's tools against its own `games/` folder. The folder name `roblox-core/` is
what the tools expect (`STUDWORK_CORE_DIR`). The StudWork repo itself has no `games/`; its example
games are in `examples/`. Supported since v1.4.0.

## Layout

```
<games-repo>/
  roblox-core/                 this repo as a git submodule, checked out at a tag (vX.Y.Z)
  games/<name>/                one folder per game (tools/new-game)
    default.project.json       $paths into ../../roblox-core/packages/... and ../../roblox-core/deps/...
    deploy.json                servePort, test/live ids, the publish stamps
    src/  modules/<name>/      the game (Config, Main scripts, the game's own module)
  tools/                       thin wrappers: tools/<x> runs roblox-core/tools/<x> on this repo
  .githooks/pre-commit         tools/lint + tools/test
  docs/games/<name>.md         design docs (tools/new-game)
  GAMES.md                     the game list (tools/new-game adds rows, tools/publish fills "Core")
  FRAMEWORK_REQUESTS.md        what the games need from the framework (games never edit roblox-core/)
  .env                         git-ignored: ROBLOX_OPEN_CLOUD_API_KEY for tools/publish
  .gitignore                   /.cache/, /build/, *.rbxl, .env (from templates/games-repo/gitignore)
```

## How the tools find the games (the mechanism)

Every core tool sources `tools/_common.sh`, which knows two roots:

- **the core root**: where the tool itself lives (`roblox-core/` in a games repo);
- **the project root**: `$STUDWORK_PROJECT_ROOT`, default the core root (so in the core repo
  nothing changes). The core must be inside the project root; its path relative to the project is
  `STUDWORK_CORE_DIR` (`roblox-core`).

Tools `cd` to the project root and export both variables. The Lune tools read them through
`tools/lune/Roots.luau`: core files are reached as `Roots.core(path)` (`roblox-core/packages/...`),
the project's games are `games/*` (`Roots.gameDirs`). Every path stays **relative**, so the Rojo
`$path`s that `tools/new-game`, `tools/make-module` and `tools/sync-projects` write are computed from
each project file to the core (`../../roblox-core/packages/kits/economy/Economy/module.luau`) and
nothing absolute ends up in a committed file. The Lune testkit and the multi-server sim map
`ReplicatedStorage.Framework`, the kit modules and `deps/Packages` into `roblox-core/` the same way.

The games repo's `tools/_studwork` sets `STUDWORK_PROJECT_ROOT` to the games repo and runs
`roblox-core/tools/<tool>`; every other wrapper is one line (`exec tools/_studwork lint "$@"`).

**Toolchain and packages come from the core.** Rokit's shims pick versions from the `rokit.toml`
above the working directory, and a games repo has none, so in a games repo the tools put
`.cache/studwork-bin/` first on `PATH`: links to the exact binaries the core's `rokit.toml` pins
(from Rokit's tool storage, installed by `tools/install`). Wally packages are installed into
`roblox-core/deps/` (git-ignored inside the submodule) and every game maps
`../../roblox-core/deps/Packages`. A games repo never duplicates a version pin.

## Set up a games repo

```sh
git init my-games && cd my-games
git submodule add <url-or-path-of-studwork> roblox-core
#   a local path: git blocks the file transport by default, so allow it for this command:
#   git -c protocol.file.allow=always submodule add /path/to/studwork roblox-core
git -C roblox-core checkout v1.5.0
cp -R roblox-core/templates/games-repo/. .
mv gitignore .gitignore && mv env.example .env.example && rm README.md
git add -A && git commit -m "games repo on StudWork v1.5.0"
tools/install            # rokit install + wally install into roblox-core/deps/ + this repo's hook
tools/doctor             # every line ok, incl. "framework pin  roblox-core/ at v1.5.0, clean"
```

A fresh clone of the games repo needs the submodule first:

```sh
git submodule update --init
#   local path submodule:  git -c protocol.file.allow=always submodule update --init
tools/install
```

## Everyday commands (from the games repo root)

```sh
tools/new-game <name> [--modules A,B,C] [--no-design-doc]   # games/<name>, $paths into roblox-core/
tools/make-module <Name> --game <name> [--net]               # games/<name>/modules/<name-kebab>/
tools/make-screen <name> <ScreenName>
tools/make-migration <module-dir | ModuleName>
tools/lint                     # selene + stylua (core configs) over games/, sync-projects --check,
                               # guardrails (modules, numbers, remotes, purchases, packages,
                               # special, theme) + the framework pin
tools/typecheck <name>|--all   # luau-lsp strict over the game's src/ and modules/
tools/test [paths]             # the games' specs (Boot.spec boots each game in the sim)
tools/build [name|--all]       # rojo build -> build/<name>.rbxl
tools/dev <name>               # rojo serve on the game's port + Studio steps
tools/net                      # Blink for the games' .blink files
tools/sync-projects            # regenerate the kit module entries of every game project
tools/framework-status         # each game's stamped StudWork version vs the pinned tag (core's tools/core-status)
tools/doctor
tools/publish <name> --test|--live [--dry-run]               # uploads to Roblox: --dry-run first
```

`tools/test-sim` and `tools/bench` are framework suites: they run in the core repo.

## The framework pin (guardrail)

Game work never edits `roblox-core/`. `tools/lint` (and so the pre-commit hook) fails when:

- `roblox-core/` is not a git checkout (submodule not initialised);
- its HEAD is not exactly a release tag (`git -C roblox-core describe --tags --exact-match`);
- it has local changes (`git -C roblox-core status --porcelain`);
- the `packages` check: a `game/*` branch changes `roblox-core` (the pointer or anything under it),
  or one commit stages a game folder together with the `roblox-core` pointer (bump the framework in
  its own commit).

Need something from the framework? Add an entry to `FRAMEWORK_REQUESTS.md` and ship it as a
StudWork release (or open an issue or pull request on StudWork); then bump the pin.

## Bumping the framework to a new tag

```sh
git -C roblox-core fetch --tags
git -C roblox-core checkout v1.5.0
tools/install                  # new pins / packages, if any
tools/lint && tools/typecheck --all && tools/test && tools/build
git add roblox-core && git commit -m "framework: StudWork v1.5.0"   # nothing else in this commit
tools/framework-status         # games show "behind" until they are published again
```

Read `roblox-core/packages/framework/CHANGELOG.md` first. Module ranges like `framework = "^1.3.0"`
keep matching every 1.x release.

## Publish

`tools/publish <name> --test|--live [--dry-run]` works as in the core (gate, checks, rojo build,
Open Cloud upload, stamp), with the games repo as the project:

- `games/<name>/deploy.json` holds the ids and receives the stamps: `coreVersion` (StudWork version),
  `coreCommit` (last framework commit, short), `coreSha` (the full commit of the pinned
  `roblox-core/`), `coreTag` (its tag), `coreStamp`, and `<target>.published` / `.dryRun` with the
  games repo commit;
- the key comes from the games repo's environment or its git-ignored `.env`
  (`ROBLOX_OPEN_CLOUD_API_KEY`; `.env.example` names it), never from the core;
- the build inputs that must be clean for a real publish (and unchanged between `--test` and
  `--live`) are the game folder and the `roblox-core` submodule;
- `GAMES.md`'s "Core" column is updated.

Always `--dry-run` first; a real publish uploads to Roblox, so check the target ids before you run it. The one-time Roblox setup and the launch checklist: [publishing.md](publishing.md).

## Testing the mechanism

`tools/test-games-repo` (in the core repo) builds a throwaway games repo in `$TMPDIR` with a snapshot
of the core as its `roblox-core/` submodule (tagged `v<StudWork.VERSION>` in the temp copy only) and
the `templates/games-repo/` skeleton, then runs the wrappers: new-game, make-module, lint, typecheck,
test, build, publish --dry-run (stamps checked), framework-status, doctor, dev --print, and the pin
failures (dirty submodule, untagged HEAD).
