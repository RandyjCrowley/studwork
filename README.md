# StudWork (roblox-core)

**StudWork** is an opinionated Roblox game framework, written in Luau (`--!strict`). It makes good
decisions for you, so a new game is playable within minutes: a game that sets only its name and
items gets rarity tiers, a mobile-first theme, a HUD, an income economy, luck with disclosed odds,
rebirth, streaks, offline earnings and co-play detection. Every one of those decisions can be
overridden, in five levels (use the defaults, change config, replace a piece, switch a kit off,
write your own module), so the framework never becomes something you have to work around.

It is a small foundation (`packages/framework`: boot, save sections with migrations and atomic
transactions, receipt-safe purchases, validated and rate-limited networking, compliance for paid
random items, replication), optional kit modules (`packages/kits`: collection, economy, base,
social, engagement), a theme-driven React UI kit (`packages/ui`) and the tools around them
(lint with guardrails you can't turn off, strict type checking, a Lune test harness and a
multi-server simulation, generators, publish). Nothing in core is special: the built-in kits use
the same public module API a third-party module does.

This repo is the framework only. Games live in a separate **games repo** that has this repo as a
git submodule (`roblox-core/`, pinned at a release tag) and runs these tools against its own
games ([docs/framework/games-repo.md](docs/framework/games-repo.md)). Why it is built this way:
[docs/philosophy.md](docs/philosophy.md).

## 5-minute start

Needs [Rokit](https://github.com/rojo-rbx/rokit) (it installs the pinned Rojo, Wally, Lune, Selene,
StyLua, Blink and luau-lsp from `rokit.toml`). Wally 0.3.2 ships only an x86_64 macOS binary, so
Apple Silicon needs Rosetta 2.

```sh
tools/install          # rokit install + wally install (deps/) + the pre-commit hook
tools/doctor           # toolchain, packages, hook, ports, layout: every line should say ok
tools/test             # Lune specs (framework, kits, tools, examples)
rojo build examples/sandbox/default.project.json -o build/sandbox.rbxl   # or:
tools/dev sandbox      # rojo serve examples/sandbox + the Studio connect steps
```

`examples/sandbox` is a playable reference game that uses every kit; `examples/overrides/ov-a` …
`ov-f` show one override case each. To make a real game, work in a games repo:

```sh
tools/new-game my-game --modules Items,Rarity,Inventory,Economy   # in the games repo (its tools/ wrapper)
```

Setting up a games repo, its wrappers and the everyday commands:
[docs/framework/games-repo.md](docs/framework/games-repo.md).

## Docs

- [docs/framework/](docs/framework/README.md): getting started, concepts, override levels, the module
  API reference, generators, kits, theme, guardrails, FAQ.
- [docs/framework/module-api.md](docs/framework/module-api.md): the module API contract (source of
  truth; additive only).
- [packages/framework/CHANGELOG.md](packages/framework/CHANGELOG.md): every release.
- [docs/decisions.md](docs/decisions.md): why things are the way they are;
  [docs/known-issues.md](docs/known-issues.md): what is still open.
- [CLAUDE.md](CLAUDE.md): rules for agents (and people) working on the framework itself.

## Licence

To be decided.
