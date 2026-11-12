# AGENTS.md: start here (any coding agent)

**StudWork** is an opinionated Roblox game framework in Luau (`--!strict`): a small foundation, optional
kit modules, a React UI kit and offline tools (lint, typecheck, Lune tests, build, publish).
Games don't live in this repo; each game is its own repo with StudWork pinned as a `studwork/` submodule.

## Which task are you doing?

| You were asked to... | Read this, then follow it |
|---|---|
| **Migrate an existing Roblox game to StudWork** ("here's StudWork, here's my game, migrate it") | [docs/agents/adopt-existing-game.md](docs/agents/adopt-existing-game.md), the step-by-step playbook. The design behind it: [docs/framework/adopting.md](docs/framework/adopting.md) |
| **Build a new game** | [README.md](README.md) "Quick start" (`tools/new-project my-game`), then the new project's own `CLAUDE.md` and [docs/framework/getting-started.md](docs/framework/getting-started.md) |
| **Work on a game that already uses StudWork** | That project's `CLAUDE.md` and `README.md`; the API is [docs/framework/module-api.md](docs/framework/module-api.md) (source of truth; [module-reference.md](docs/framework/module-reference.md) is the current summary) |
| **Change the framework itself** (this repo) | [CLAUDE.md](CLAUDE.md). Its hard rules bind every change here |

This file only routes. Where it and `CLAUDE.md` seem to differ, `CLAUDE.md` wins for work on this
repo, and the playbook wins for a migration.

## Hard rules (one screen)

1. **Never publish to Roblox, never touch live data.** No `tools/publish --live`, no Open Cloud
   calls, no real DataStores. Publishing and cutover are the user's job.
2. **Never write an old game's DataStore.** StudWork only reads old saves, at join, through
   `ctx.data.importLegacy`.
3. **Never edit `studwork/`** (the submodule) from a game. Framework changes are requests to the user.
4. **The server is authoritative.** Clients send requests to module actions; the server validates
   every argument. Never trust an amount, price, item id or position sent by a client.
5. **Robux purchases go through `ctx.shop.onProduct`** (the framework owns `ProcessReceipt`).
   Paid random items go through `ctx.compliance` with odds shown.
6. **Network and saves only through the framework:** no `RemoteEvent`/`OnServerEvent`,
   `DataStoreService`, ProfileService/ProfileStore or DataStore2 in new code.
7. **Balance numbers live in config.**
8. **`tools/lint` stays clean.** Never use `git commit --no-verify`.
9. **Git:** work on a branch, commit only your own files, never push, merge, tag or rewrite
   history unless the user asks.
10. **Stop and ask the user** before installing anything outside the project, using `sudo`,
    spending money, publishing, or touching files outside the project.
11. **No secrets and no absolute paths** in committed files.

## Where the docs are

- [docs/README.md](docs/README.md): the docs index.
- [docs/agents/](docs/agents/): agent playbooks ([adopt-existing-game.md](docs/agents/adopt-existing-game.md),
  [migrate-prompt.md](docs/agents/migrate-prompt.md)).
- [docs/framework/module-api.md](docs/framework/module-api.md): the module API (source of truth); [module-reference.md](docs/framework/module-reference.md) is its current summary.
- [docs/framework/guardrails.md](docs/framework/guardrails.md): what `tools/lint` refuses and why.
- [docs/framework/kits/](docs/framework/kits/): each kit's config, API and save data.
