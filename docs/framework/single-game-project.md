# Single-game projects

A **single-game project** is the simplest way to build one game on StudWork: the repository root
*is* the game, and StudWork is a git submodule at `studwork/`, pinned at a release tag. One
command creates it, and every tool works with no game name. Supported since v1.5.0.

The other layout, one repo holding several games (`games/<name>/`) with StudWork at `roblox-core/`,
is described in [games-repo.md](games-repo.md). Both stay supported; pick single-game unless you
want several games to share one repo, one framework pin and one `GAMES.md`.

## Create one

From any StudWork checkout (a clone of this repo, or an existing project's `studwork/`):

```sh
tools/new-project ../my-game --modules Items,Rarity,Inventory,Economy
cd ../my-game
tools/doctor
tools/dev
```

`tools/new-project <path> [options]`:

| Option | Default | What |
|---|---|---|
| `--name <gameId>` | the folder name | the game id (lowercase, digits, dashes; same rule as `tools/new-game`) |
| `--modules A,B,…` | every kit module | kit modules to enable; missing dependencies are added and reported (`tools/new-game --modules`) |
| `--url <studwork-url>` | `https://github.com/RandyjCrowley/studwork.git` | where the submodule is cloned from; a local path works too (git's `protocol.file.allow=always` is passed for it) |
| `--tag vX.Y.Z` | `v<StudWork.VERSION>` of the checkout running the tool | the release tag the submodule is pinned at; refused if the tag doesn't exist there or predates v1.5.0 |
| `--no-install` | install | skip `rokit install` / `wally install`; copy the running checkout's `deps/Packages` and `deps/ServerPackages` into `studwork/deps/` instead (tests, offline) |
| `--author-name`, `--author-email` | see below | the new repo's repo-local git identity |

It refuses a `<path>` that exists and is not empty, and removes what it created if a step fails.
Steps:

1. `git init -b main`, then the repo-local identity: `--author-name/--author-email`, else
   `$STUDWORK_AUTHOR_NAME/$STUDWORK_AUTHOR_EMAIL`, else the running checkout's own repo-local
   `user.name`/`user.email` (`git config --local`); with none of these, git's global identity applies.
2. `git submodule add <url> studwork`, then `git -C studwork checkout <tag>`.
3. The game at the root: `studwork/tools/new-game` (template `templates/new-game`, `$path`s into
   `studwork/`, `docs/design.md` from `templates/game-design.md`), then the skeleton from
   `studwork/templates/single-game`: the `studwork.json` marker, `tools/` wrappers,
   `.githooks/pre-commit`, `.gitignore`, `.env.example`, `README.md`, `CLAUDE.md` (rules for game
   agents), `FRAMEWORK_REQUESTS.md`.
4. `tools/install` in the new project (toolchain + Wally packages into `studwork/deps/` + the hook).
5. The first commit, through the project's real pre-commit hook (lint + tests). It is the one
   commit allowed to add the `studwork` pointer together with other files: nothing is bumped yet
   (the guardrail checks that the repo has no `HEAD`).

No project file gets an absolute path. `.gitmodules` holds the `--url` as given (the public URL by
default).

## Layout

```
<project>/
├─ studwork/                  StudWork, git submodule pinned to a tag (never edited here)
├─ studwork.json              the layout marker: {"layout": "single-game"}
├─ default.project.json       Rojo project at the root ($paths "studwork/packages/...", "studwork/deps/...")
├─ deploy.json                servePort, test/live ids (0 = placeholder), the framework stamps
├─ .env.example  .gitignore  .githooks/pre-commit
├─ src/server/                Main.server.luau, ServerConfig.luau, World.luau, Boot.spec.luau
├─ src/client/                Main.client.luau
├─ src/shared/Config/         init, Balance, Items, Products, Events, Palette, Tuning (+ Config.spec.luau)
├─ modules/<game-id>/         the game's own module; more from tools/make-module sit next to it
├─ docs/design.md             the design doc
├─ tools/                     one-line wrappers -> studwork/tools/* (+ tools/_studwork)
├─ README.md  CLAUDE.md  FRAMEWORK_REQUESTS.md
```

The game's modules live in `modules/<name>/` (not a single `module/`): module discovery,
`tools/make-module`, `tools/sync-projects`, the guardrails and the new-game template all use
`modules/*`, and a game can have more than one module (`docs/decisions.md`).

## How the tools know (detection)

The tools recognise three layouts. `tools/_common.sh` decides and exports `STUDWORK_LAYOUT`;
`tools/lune/Roots.luau` reads it (and, when a Lune tool runs on its own, makes the same decision
from the files):

| Layout | When | Games |
|---|---|---|
| `core` | the project is the StudWork repo itself (`STUDWORK_CORE_DIR` = `.`) | `examples/`, `examples/overrides/`, scratch `games/` |
| `single-game` | the core is a subfolder and the project root has `studwork.json` with `"layout": "single-game"` | the root (`.`) |
| `games-repo` | the core is a subfolder, no marker | `games/<name>/` |

The marker is a committed file, so a fresh clone, CI and the pre-commit hook all see the same
layout; it never depends on a folder's name. In a single-game project `Roots.GAME_PARENTS` is empty,
`Roots.gameDirs` returns `{ "." }` and `Roots.findGame` returns `"."` for no name, `"."` or the
`deploy.json` name; the bash side's `game_dir` does the same. `Roots.external` is true (the core is
a submodule), so everything games repos get applies here too: the `.cache/studwork-bin` toolchain
links and the git shim (`tools/_common.sh`).

## Everyday commands (no game name)

```sh
tools/install                 # toolchain + Wally packages into studwork/deps/ + hook (--hooks-only)
tools/doctor                  # toolchain, packages, hook, framework pin, .env keys (never values), port
tools/lint                    # selene + stylua --check (every top-level folder except studwork/, build/,
                              # hidden ones) + sync-projects --check + guardrails + framework pin
tools/typecheck               # luau-lsp strict over src/ and modules/
tools/test [paths]            # Lune specs of the project (never studwork/)
tools/build                   # build/<deploy.json name>.rbxl
tools/dev [--print]           # rojo serve default.project.json on the game's port
tools/make-module <Name>      # modules/<name>/, mapped in default.project.json
tools/make-screen <Name>      # src/client/Screens/<Name>.luau
tools/make-migration <module>
tools/sync-projects [--check] # the root *.project.json files
tools/net                     # Blink codegen in src/ and modules/
tools/framework-status        # the pinned studwork/ tag vs the stamp in deploy.json
tools/publish --test|--live [--dry-run]
```

The game's name is still accepted where a tool took one (`tools/build my-game`, `tools/publish
my-game --test`). `tools/new-game` refuses: the project already is its game (start another one with
`tools/new-project`). `tools/test-sim` and `tools/bench` are framework suites; they run in the
StudWork repo.

## The framework pin

Same rules as a games repo, against `studwork/` (`tools/lint`, [guardrails.md](guardrails.md)
`packages`):

- `studwork/` must be an initialised git checkout, exactly at a release tag (`vX.Y.Z`), with no
  local changes. Never edit it; ask for changes in `FRAMEWORK_REQUESTS.md` or an issue on StudWork.
- A commit that stages the `studwork` pointer together with any other file is refused (the root is
  the game, so every other file is game work): bump the framework in its own commit. The project's
  first commit is the exception (it has no parent; nothing is bumped).
- On a `game/*` branch the pointer must not move.

## Bumping StudWork

```sh
git -C studwork fetch --tags
git -C studwork checkout vX.Y.Z      # read studwork/CHANGELOG.md first
tools/install                         # the new pins (toolchain, Wally packages)
tools/lint && tools/test && tools/build
git commit -m "StudWork vX.Y.Z" studwork
tools/framework-status                # the pinned tag; deploy.json is restamped on the next publish
```

## Publish

[publishing.md](publishing.md) has the one-time setup. In a single-game project:

- `tools/publish --test --dry-run`, `tools/publish --test`, then `tools/publish --live` (refused
  unless the same build inputs went to test first).
- `deploy.json` at the root is stamped: `coreVersion`, `coreCommit`, `coreSha` (the submodule's
  commit), `coreTag`, `coreStamp`, and `test.dryRun` / `<target>.published`. There is no
  `GAMES.md` to update.
- The clean-tree gate covers the whole project and the `studwork` submodule (`deploy.json`
  excepted): commit everything before a real publish.
- The place file is `build/<name>-<target>.rbxl`.

## A fresh clone

```sh
git clone <your-project-url> my-game && cd my-game
git submodule update --init           # studwork/ at the pinned tag
tools/install                          # toolchain + Wally packages + hook
tools/doctor
```

## Testing (StudWork maintainers)

`tools/test-single-game [--keep]` (run by `tools/test` with no arguments, so by CI) builds a
throwaway project in `$TMPDIR`: a snapshot of the working tree tagged `v<StudWork.VERSION>` as a
local fixture remote, then `tools/new-project … --url <fixture> --modules Items,Rarity,Inventory,Economy
--no-install`, and checks the submodule tag, the `$path`s, that no committed file has an absolute
path, the identity and the first commit; then the project's own wrappers with no game argument
(lint, typecheck, test, build, make-module, make-screen, sync-projects, publish `--test --dry-run`,
framework-status, doctor, dev `--print`, new-game refused), planted failures (type error, undefined
global, raw remote, dirty and untagged submodule) and real commits through the hook (normal,
partial, a mixed bump refused, the bump alone).
