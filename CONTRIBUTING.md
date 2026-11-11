# Contributing to StudWork

Thanks for helping. This page covers setup, the checks, the rules every change follows, and how
to propose a change. By contributing you agree that your contribution is licensed under the
[MIT licence](LICENSE) of this project. Please follow the [code of conduct](CODE_OF_CONDUCT.md).

## Setup

You need macOS or Linux with `bash`, [Rokit](https://github.com/rojo-rbx/rokit), and for manual
testing Roblox Studio with the Rojo plugin (see [README.md](README.md#requirements)).

```sh
tools/install              # pinned toolchain (rokit.toml) + Wally packages into deps/ + pre-commit hook
tools/install --hooks-only # only enable the pre-commit hook (tools/lint + tools/test)
tools/doctor               # checks the toolchain, packages, hook and layout
```

Never run `wally install` in the repo root: the root `wally.toml` is a publish-only manifest, and
on case-insensitive file systems Wally's `Packages/` would land in `packages/`. Dependencies are
pinned in `deps/wally.toml` and installed by `tools/install`.

## Checks

Run these before you open a pull request (CI runs the same ones):

```sh
tools/lint               # selene, stylua --check, sync-projects --check, guardrails
tools/typecheck --all    # luau-lsp strict over every example game
tools/test               # every *.spec.luau, then tools/test-games-repo
tools/test-sim           # multi-server simulation (data, purchases, cross-server)
tools/build --all        # rojo build of every example game
tools/bench              # only when you change per-tick or per-player code: stay within +20%
```

## Rules for every change

These are the project's hard rules (the full list is in [CLAUDE.md](CLAUDE.md)):

1. **The server is authoritative.** Clients only send requests (module actions). The server
   validates every argument (type, range, ownership), and every action is rate-limited by the
   framework's Net. Never trust amounts, item ids, prices or positions from a client.
2. **Network only through the framework.** Declare a module's actions and events; never use
   `RemoteEvent`/`RemoteFunction`, `OnServerEvent`, `ProcessReceipt`, `DataStoreService` or
   ProfileStore directly outside the framework. Robux purchases go through `ctx.shop.onProduct`.
3. **Every balance number lives in config**, with documented defaults.
4. **Paid random items follow the compliance rules:** odds are always disclosed (from the server);
   paid rolls go only through `ctx.compliance`; players restricted by `PolicyService` never get paid
   random items (they get a fixed fallback); paid copies can't be traded or mailed. See
   [module-api.md](docs/framework/module-api.md) §14 and §19.6–19.7.
5. **Nothing is special.** Kits, examples and modules use only the `StudWork` facade, their `ctx`,
   the UI kit and other modules' public APIs. Framework code never names a kit. The `special`
   guardrail enforces both halves.
6. **The module API is additive.** Nothing is renamed or removed within a major version; mark old
   calls `-- @deprecated <replacement>` and keep them working. New API goes in
   `docs/framework/module-api.md` as a new subsection of §19 (or later) titled `(added in <version>: <why>)`,
   plus optional fields in `packages/framework/shared/Types.luau`.
7. **Tests are required.** Add a `*.spec.luau` that fails without your change. Never weaken or
   delete an existing assertion; a moved spec keeps its test count. A guardrail change needs a
   planted violation in its `--self-test`.
8. **No secrets and no absolute paths** in committed files.
9. **Pin dependencies exactly** (`=x.y.z` in `deps/wally.toml`, `@x.y.z` in `rokit.toml`) and record
   why in `docs/decisions.md`.

## Proposing a module or a bigger change

Open an issue first (use the **Module request** or **Feature request** template). Describe the
game need, the public API you have in mind (in terms of `ctx` and `StudWork.use`), what is
config, and how it stays inside the rules above. Many requests are better as a module in your own
games repo: the kits have no access a third-party module lacks, so you rarely need a framework
change.

## Commits and pull requests

- Small, focused pull requests against `main`, one logical change each.
- Commit messages: a short summary line, then what and why.
- Update the docs page (`docs/framework/…` or the kit page), add an entry under `[Unreleased]` in
  [CHANGELOG.md](CHANGELOG.md), and the reason in `docs/decisions.md` for design changes.
- All checks green; fill in the pull request checklist.
- Don't bump `StudWork.VERSION`; maintainers do that when releasing.
