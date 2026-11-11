# Changelog

All notable changes to StudWork are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Within a major version the
module API (`docs/framework/module-api.md`, `packages/framework/shared/Types.luau`) only grows:
nothing is renamed or removed, and deprecated calls keep working.

Identifiers like `R19` or `V1` are issue ids: open ones are listed in [docs/known-issues.md](docs/known-issues.md), fixed ones in its "Fixed ids" index.

## [Unreleased]

## [1.4.1] - 2026-11-11

Public release preparation. No module API change; `framework = "^1.3.0"` ranges still match.

### Added

- `LICENSE` (MIT).
- `README.md`, `CONTRIBUTING.md`, `SECURITY.md` and `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1).
- GitHub Actions CI (lint, type check, tests, multi-server simulation, builds) and issue / pull
  request templates.
- A root `wally.toml` package manifest (`randyjcrowley/studwork`) for publishing later. It is not
  published yet; install from the repository.
- A documentation index, `docs/README.md`.

### Fixed

- The games-repo pre-commit hook template no longer trips the framework pin check when run by
  git: git hands hooks a relative `GIT_INDEX_FILE`, which broke the check's git calls inside the
  submodule. Covered by `tools/test-games-repo`.

### Changed

- Internal build history (build reports, prompts) removed from the repository; docs rewritten for
  outside readers.
- Example game and fixture names made generic (`example-collector`, `example-courier`, ...).
- The development dependency manifest (`deps/wally.toml`) is renamed `randyjcrowley/studwork-deps`.

## [1.4.0] - 2026-11-11

StudWork from a separate games repo. The framework is its own repository; games live in a
**games repo** that has it as the `roblox-core/` git submodule, pinned at a release tag
([docs/framework/games-repo.md](docs/framework/games-repo.md)). Tooling only: the module API is
unchanged.

### Added

- **Games-repo mode for every tool.** Tools take the project root from `STUDWORK_PROJECT_ROOT`
  (default: the framework repo itself) and the framework root from their own location
  (`tools/_common.sh`, `tools/lune/Roots.luau`). Works for `lint`, `typecheck`, `test`, `build`,
  `new-game`, `make-module`, `make-screen`, `make-migration`, `publish`, `dev`, `net`,
  `sync-projects`, `doctor`, `core-status` and `install` (toolchain and packages always come from the
  framework's pins; games never duplicate a version pin).
- `templates/games-repo/`: a games-repo skeleton (tool wrappers, pre-commit hook, `.gitignore`,
  `.env.example`, `GAMES.md`, `FRAMEWORK_REQUESTS.md`).
- **Framework pin guardrail** (games repo): lint fails when `roblox-core/` is not initialised, is not
  checked out exactly at a release tag, or has local changes. `tools/doctor` shows the pin.
- `tools/publish` stamps the exact framework in `deploy.json` (`coreSha`, `coreTag`).
- `tools/build [game|--all]`: Rojo build of every game to `build/`.
- `tools/test-games-repo`: builds a throwaway games repo with a snapshot of the framework as its
  submodule and runs the tools end to end, including planted failures. `tools/test` runs it after
  the specs.
- `tools/new-game --into <folder>` and `tools/typecheck --all`.
- `tools/sync-projects` generates an example module into any project that maps it.
- Generator templates are plain files (`templates/module/`, `templates/migration/`,
  `templates/screen/`).
- Example games in the repo: `examples/sandbox` (every kit) and the override cases
  `examples/overrides/ov-a` … `ov-f`, each with its own spec.

### Fixed

- `tools/doctor` crashed on a plain file inside a kit folder.
- The `packages` guardrail no longer treats the framework repo's own `templates/` as game work.

## [1.3.1] - 2026-11-11

"Nothing is special", for real: kits no longer get any help from the framework that a third-party
module couldn't get (R19); paid currencies are enforced at boot (R20); `saveNow` keeps the framework
section current (R22). The public module API (`defineModule`, `ctx`, `StudWork.use`, actions,
`StudWork.test`) only gained things; the breaking changes below are kit internals and wire names.

### Breaking

- **Kit network events moved out of the framework.** The kit request events left
  `framework.blink`. Each kit module has its own `net.blink` backing module actions with the same
  names, wire types and rate limits (Plot `display`/`clearDisplay`, Upgrades `upgrade`, Rebirth
  `rebirth`, Rarity `roll`, Inventory `gift`, Mail `claimMail`). Clients call
  `StudWork.use(<Ref>).actions.<name>(...)`; tests call `h:action(p, <Ref>, "<name>", ...)`.
- **Boot fails if a paid currency has no registered spender** (module-api.md §19.10).
- **Economy owns only its own paid currencies**: `primaryCurrency` plus the new optional
  `config.Economy.currencies`. A paid currency that isn't Economy's primary must be listed there (or
  owned by another module).
- **One folder per kit module** (`packages/kits/<kit>/<Module>/`: `module.luau`, `server/`,
  optional `client/`, `shared/`, `net.blink`). A definition is `ReplicatedStorage.Modules.<Name>.module`,
  a server part `ServerScriptService.Modules.<Name>`; `ReplicatedStorage.Kits` /
  `ServerScriptService.Kits` are gone. `tools/sync-projects` writes the project entries.
- Rarity tiers moved to `ReplicatedStorage.Modules.Rarity.shared.Tiers`.
- The kit loader fallbacks are removed; module-api.md §19.9 is the only part lookup.
- Kit-named client actions, `StudWork.Client.onMailbox` (now `StudWork.use(Mail).onMailbox`) and
  the kit HUD slices moved from the framework client to the kits' client parts. The default HUD
  widgets `"Economy.currency"` and `"Social.mailbox"` keep their ids, slots and order.
- The `Feedback` wire field `Rarity` is now `Tier` (framework wire only).
- `Types.ModuleName` is `string`; the old facade type's kit namespaces are removed.

### Added

- module-api.md §19.9 (live part lookups) and §19.10 (paid-currency spender rule).
- Client parts for Plot, Upgrades, Rebirth, Rarity, Inventory, Mail and Economy.
- `tools/sync-projects [--check]` (lint fails on drift) and one shared module discovery for the
  testkit, the simulation, sync-projects and the guardrails.
- `tools/make-module --net`: a module `net.blink` with the per-module conventions.
- The `special` guardrail now also checks framework code: it may not name a kit module or a kit's
  network event, with no allow-list.
- `tools/doctor` / `tools/core-status` check the per-module kit layout.

### Fixed

- `Store.saveNow` and `Data.saveAsync` bump the framework section version when a save replaces it,
  so views and replication are current right after a save (R22).
- The framework's `special` scan ignores `-- guard: allow special`.
- Net logs a module action that has no event in the module's `net.blink` (it was bound silently).
- Client actions declared in list form (`actions = { "roll" }`) are recognised by the tools.

## [1.3.0] - 2026-11-11

The StudWork framework restructure: a small foundation plus optional kit modules that use only the
public module API ([docs/framework/module-api.md](docs/framework/module-api.md)). This was the last
release allowed to break the API; since then it only grows.

### Breaking

- **`Core.*` is replaced by `StudWork.*`**, with no alias: `require(ReplicatedStorage.Framework)`,
  `StudWork.start(Config, ServerConfig)`, `StudWork.use`, `StudWork.defineModule`,
  `StudWork.Client`, `StudWork.test`. A game's own gameplay code is its own module.
  `GameConfig.modules` takes module refs; each module's config lives in `config.<Name>`;
  `compliance.paidCurrencies` is top level.
- **One save section per module.** v1.2 saves migrate automatically (proven by a full migration
  spec).
- **Kits:**
  - Collection: `incomePerSec` moved to `item.economy.incomePerSec`; `Items.register` /
    `Items.onRegistered` removed (items exist only through `GameConfig.items`, validated at boot;
    registering later errors, so no item can enter a paid table before its odds are disclosed);
    Robux copies are tagged `paid:<product>`; caller-chosen paid tags are refused.
  - Economy: spending a paid currency through `Economy.spend` errors (use
    `compliance.spendForRoll` / `compliance.spendPaid`); rebirth never wipes Robux-bought copies.
  - Plot reads `plot.keepDisplayedOnRebirth`; gifts are capped per recipient (100 undelivered) and
    return to the sender after 14 days.
  - Console commands are module-prefixed (`economy grant`, `rarity roll`, `shop receipt`, ...).
- **Theme:** one merged theme; tokens `panel`/`secondary` → `surface`/`accentAlt`,
  `metrics.outline` → `metrics.strokeThickness`, `metrics.minTouch` → `metrics.minTouchTarget`.
- **Compliance:** a paid roll needs the source's odds to have been sent to that player's client, at
  any luck (purchases without them are retried, `odds_not_disclosed`).
- The v1.2 compatibility layer (`packages/core`, `packages/kits/compat`) is deleted.

### Added

- The module API: `defineModule`, `ctx` services, save sections with migrations, atomic
  transactions across modules (`ctx.tx`, `depsTx`), module actions, a framework shared store.
- `StudWork.test`: the public test harness (real kit modules, purchases with re-delivery, a shared
  memory store with failure injection, a multi-server simulation on real ProfileStore session locks).
- `ctx.compliance.spendPaid(tx, currency, amount, reason)` for spending a paid currency on a
  non-random good; any later roll in that transaction counts as paid.
- Guardrails `special` (nothing is special) and `theme` (no colour or asset literals in UI code).
- The five override levels, each covered by a spec; `tools/doctor` / `tools/core-status` check the
  layout; `tools/bench` variants with the real kits.

### Changed

- Tick cost under budget again: commits share unchanged subtrees and replication reuses unchanged
  frozen data (0.60 ms per tick at 50 players × 100 items).
- The UI kit fits text for any theme font.

### Fixed

- Guardrails scan every synced file and normalise text evasions.
- Committed save sections are frozen: a kept section reference can't change committed data.
- Forged paid tags are stripped.
- Unknown theme keys warn at boot; a gap in migration numbers is a boot error naming the missing number.

## [1.2.0] - 2026-11-10

Finishing the platform: mailbox, luck with disclosed odds, multi-server tests, publishing.
Additive, with one behaviour change.

### Changed

- A Mail handler returning `false` no longer counts as a failure: the message waits in the player's
  mailbox until claimed.

### Added

- Mail mailbox (`Mail.pending`, `Mail.claim`, cap, tuning) and outbox (save before send, resend
  with the same key); `Inventory.sendGift`. A property test (40 seeds × 300 steps) shows gifted
  items are never duplicated or lost.
- Per-player luck with luck-aware disclosed odds (`Rarity.setLuck`, `Rarity.getLuck`,
  `luckDisclosed` tables). A paid roll with luck other than 1 errors unless the table discloses luck
  and the client received odds at that luck. Monte Carlo checks at several luck levels.
- A multi-server simulation on Lune (real data layer and ProfileStore session locks on a mock
  DataStore, virtual clock) and `tools/test-sim`; `docs/manual-qa.md`.
- `tools/publish` with gates (tests before live, clean tree, placeholder ids, secret-safe API key,
  dry run, stamping), the pre-commit hook via `tools/install`, `tools/dev`, `tools/doctor`,
  `tools/new-game --modules`.
- Guardrails (`modules`, `packages`, `numbers`, `remotes`) with `--self-test`, wired into `tools/lint`.
- `Net.handle` for game events through the framework's rate-limited Net.

### Fixed

- Legacy mail ids include a payload hash.
- In Studio, read APIs return frozen copies, so an in-place write errors instead of silently
  skipping replication.
- Purchases dropped when a player leaves are logged.
- Tables priced in a paid currency count as paid; luck set for all tables doesn't reach paid rolls on
  undisclosed tables; several guardrail evasions closed.

## [1.1.0] - 2026-11-10

Hardening: odds disclosure, replication cost, reliable mail, receipt-safe purchases.

### Breaking

- `GameConfig.modules` is required: a small foundation plus optional modules.
- Read-only, frozen facade; calling a server API before start errors.
- `Shop.onProduct` takes a data-only handler `(data, receipt, tx)`; decline with `tx.retryLater()`
  or by erroring.
- Mail handlers receive an `info` argument and may report failure.
- Rebirth keeps Robux-bought items by default.

### Added

- Full odds disclosure (items, mutations, pity) replicated to the client and shown in the odds UI;
  Monte Carlo spec (200k seeded rolls).
- `ServerConfig.admins` (`GameConfig.admins` is deprecated but still honoured).
- Mail idempotency keys, retries with backoff and dead letters.
- `deploy.json` framework version stamps and `tools/core-status`.

### Changed

- Replication copies only changed sections: 12.9 ms → 0.64 ms per tick at 50 players × 100 items.

### Fixed

- Purchases: the grant and the receipt record are one non-yielding commit; `PurchaseGranted` only
  after the save is confirmed (property test: never a double grant, never a record without its grant).
- A failed migration kicks with a friendly message and never saves defaults over a profile.
- Plot ownership checked before any slot lookup; bounded store wait; Net queues requests before start.
- Rolls priced in a paid currency are tagged `paidcur:<table>` (same trade and policy rules, wiped by
  rebirth).
- A failed PolicyService lookup keeps retrying instead of staying unknown.
- A start that throws part-way marks the framework unusable with the boot error.
- Mail ignores deliveries for players who already left.

## [1.0.0] - 2026-11-10

First release: the foundation services and kits.

### Added

- Data on ProfileStore (sessions, versioned migrations, sanitising, `saveAsync`), Economy, Upgrades,
  Rebirth, Offline earnings, Items, Rarity (luck, pity, mutations, exact odds), Inventory, Policy
  (fail-closed PolicyService lookups), Plot, Shop (idempotent receipts, save before grant), Streak,
  Friends (co-play), Events, Analytics.
- `Policy.isKnown(player)` and paid currencies: rolls priced in a currency sold for Robux are paid
  random items.
- Server console for Studio and admins.
- Client: replication of the local player's state, feedback (pops, sounds, reduced motion), input
  abstraction, a React UI kit and HUD.

### Fixed

- `Data.saveAsync` kept working after one failed save.
- Players restricted by PolicyService get a fixed non-random fallback for paid random products
  instead of an unprocessed purchase loop.
- Leaving or shutting down no longer kicks with "opened in another server".

[Unreleased]: https://github.com/RandyjCrowley/studwork/compare/v1.4.1...HEAD
[1.4.1]: https://github.com/RandyjCrowley/studwork/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/RandyjCrowley/studwork/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/RandyjCrowley/studwork/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/RandyjCrowley/studwork/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/RandyjCrowley/studwork/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/RandyjCrowley/studwork/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/RandyjCrowley/studwork/releases/tag/v1.0.0
