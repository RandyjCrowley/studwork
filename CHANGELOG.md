# Changelog

All notable changes to StudWork are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Within a major version the
module API (`docs/framework/module-api.md`, `packages/framework/shared/Types.luau`) only grows:
nothing is renamed or removed, and deprecated calls keep working.

Identifiers like `R19` or `V1` are issue ids: open ones are listed in [docs/known-issues.md](docs/known-issues.md), fixed ones in its "Fixed ids" index.

## [Unreleased]

### Added

- **Four kit modules**, all normal modules on the public module API (a game lists them in
  `GameConfig.modules`; each works when left out):
  - **Notifications** (engagement kit): experience notifications through Open Cloud with the key in
    Roblox's secrets store. Opt-in prompt rules, message templates, per-player and per-server limits,
    quiet hours, future sends on a shared due list that any running server sends, strict launch data.
    API `send`, `schedule`, `cancel`, `suggestOptIn` (returns `(boolean, reason?)`: a live `Player` is
    accepted, and a refusal says why); signals `Sent`, `OptInPrompted`, `LaunchedFrom`.
  - **Leaderboards** (engagement kit): all-time boards on ordered stores and daily or weekly boards on
    MemoryStore sorted maps, a top N shared by every server, the player's own rank, built-in sources
    (Economy, Rebirth, Streak) and `registerSource`. API `submit`, `top`, `rank`, `refresh`,
    `registerSource`; signal `BoardRefreshed`; client `board`, `mine`, `open`, `attach`.
  - **Badges** (engagement kit): awards that are recorded first and sent once, with retries, an
    ownership check at join and triggers (`manual`, `join`, `streak`, `rebirths`, `item`, `currency`,
    `leaderboard`). API `award`, `has` (+ `txApi.award`, `purchaseOps.award`); signal `BadgeAwarded`;
    client `earned`, `onAwarded`.
  - **TextFilter** (social kit): `FilterStringAsync` by audience (`public`, `friends`, `private`),
    `IsContentSharingAllowed`, a re-display cache and kept originals that never reach clients.
    API `filter`, `textFor`, `store`, `shown`, `release`.
- **Framework features** (not modules; always on):
  - Environments and flags: `GameConfig.environments`, `StudWork.env` / `ctx.env`, `GameConfig.flags`
    and `ServerConfig.flags`, `StudWork.flags` / `ctx.flags`, a live override through `ConfigService`
    (`GameConfig.flagOverride`), and a `flags` console command. A `testOnly` flag that would be on in
    live is a boot error.
  - Localization: `defineModule.strings`, `GameConfig.strings` and `localization`, `ctx.text`,
    `StudWork.text`, `UI.text` and `UI.useText`. The UI kit's English moved into `ui.*` keys; every
    kit component label goes through them.
  - Stores: `ctx.data.ordered(name)` and `ctx.data.sortedMap(name)` (per module, budgeted, retried,
    memory-charged), `ctx.data.census()` and `GameConfig.storeBudgets`.
  - `ctx.services.get(name)` (engine services a module may use, replaceable in specs),
    `ctx.openCloud` (deny-by-default through `ServerConfig.openCloud`; data store, memory store,
    config and Luau execution paths refused) and `ctx.policy.allows(player, field)`.
- **API additions to existing modules:** `Streak.expiresAt(player)`; `Rebirth.count(player)`.
- **UI kit:** `UI.Leaderboard` (own-row token `colors.leaderboardSelf`) and `UI.LeaderboardFormat`;
  `UI.Odds.pityLine` and `luckLine` take an optional text resolver.
- **Framework kick messages** are now the strings `framework.kick.saveFailed`, `.sessionEnded` and
  `.legacyImport` (same English; `Server.KICK_*` still work), so a game can reword or translate them.
- **Lint:** new `strings` check (hard-coded English in the UI kit, kit client parts and framework client
  code) and `textfilter` check (client text reaching players or shared stores without TextFilter;
  listable in `studwork-legacy.json`); the `purchases` check also covers `ConfigService`, `:GetSecret(`,
  `:RequestAsync(` and `:PostAsync(`.
- **Tools:** `tools/sync-projects` writes `src/shared/Config/Environments.luau` from `deploy.json`
  (`--check` fails on drift) and maps a game's `src/shared/Localization` as `LocalizationService`.
  `tools/new-game --modules` and `tools/new-project --modules` know the four new modules.
- **Testing:** harness options `env`, `placeId`, `universeId`, `services`, `openCloud`, `secrets`,
  `locale`, `translator`, `storeBudgets`, `census`, `strings`, `localization`; in-memory ordered stores
  and sorted maps with Roblox's limits (`h:orderedStore`, `h:sortedMap`); fakes for BadgeService,
  TextService, UserService, ConfigService, Open Cloud, translators and the experience notification
  service. The sandbox and the new-game template show every new module, flag and string.
- **Docs:** a page per new module and feature under `docs/framework/kits/`, module API section 23,
  kit contract, guardrails, UI README, manual QA checklist ("New in v1.7.0") and known issues O8 to O12
  and U5.

  - Added after review and dogfooding: `ctx.policy.restricted(player, field)` (restriction fields,
    true until known); Notifications `actor` on `send` and `schedule` with
    `limits.perActorPerDay` (default 10, answer `"actor_limit"`); one boot log line naming every
    placeholder badge id and Notifications `messageId`; a console reply that suggests near matches
    for an unknown command (`my points` -> `mygame points`).
  - Docs and tools for game authors: `docs/framework/testing.md` (worked game-module spec, every
    harness option) and a scaffolded `src/server/GameModule.spec.luau`; `--help` / `-h` on
    `tools/new-project`, `new-game`, `build`, `dev`, `typecheck`, `make-module` and
    `make-migration` (usage, exit 0, in core, games-repo and single-game modes);
    `tools/typecheck --offline`; `tools/lint` says "run tools/format" when stylua fails.
  - Testing: the harness's fake `game` has `Workspace`, `Players` and `HttpService`; a part with a
    `net.blink` gets a recording `part.net`; `h:sent(Module?, Event?)` reads what the server sent
    to clients.

### Changed

- Badges: in Studio a record that is not sent (`awardInStudio = false`, or a placeholder id) now
  fires the client `Awarded` event and shows a toast marked "(Studio preview, not sent)", once per
  player and key per session; new config `studioFeedback` (default `true`) turns it off, and the
  `BadgeAwarded` signal still means Roblox confirmed. Live behaviour is unchanged.
- The sandbox shows each new module in Studio: a flag-gated HUD Leaderboards button
  (`leaderboardButton`), a testOnly debug label, the notifications opt-in reachable in a first
  session (`optIn.minSessions = 0` and `minSessionSeconds = 30` as demo values, `sandbox optin`) and
  a mapped `src/shared/Localization/game.csv` with English and `es` rows. The template's
  `game.csv` has one example row.
- `ctx.policy.allows` takes permission fields only; restriction fields use `ctx.policy.restricted`.
- Environments: a test universe id counts only once `live.universeIds` lists the live universe
  (otherwise it is ignored with one boot warning and the server resolves live). The order is
  studio, test place, live place, test universe, live.
- `StudWork.start` environment options (`env`, `isStudio`) count only with an injected platform
  (tests); in production they are ignored with one warning.
- The `textfilter` lint: only TextFilter's return values count as clean (a name stays tainted after
  a filter call); named handlers (`handler = f`, `actions.x = f`) and untyped parameters are scanned.
- The census bucket splits into up to 16 shards past 500 servers, each in its own sorted map.
- Notifications: a quiet-hours offset is kept in the ledger for offline recipients; a malformed
  `messageId` is a boot error. Badges: the default award budget is 80% of Roblox's limit
  (`base = 40`, `perPlayer = 28`). TextFilter: `shownMaxDays` defaults to 7, and a `textFor` cache
  miss counts against the author's rate limit (and so does a `shown` re-filter while `cache.seconds`
  is under 60).
- `StudWork.test.harness`: `h:addPlayer` returns a userdata proxy by default, like a live `Player`
  (`type(p) == "userdata"`, `typeof(p) == "Instance"`), so a `type(p) == "table"` check fails in a
  spec. A spec that uses `pairs`, `rawget`, `setmetatable` or `table.clone` on a player breaks:
  pass `instancePlayers = false` to keep plain table players.
- The scaffolded game module's description, version check and `dependsOn` comment are neutral;
  `new-game` rewrites the console prefix in the scaffold's help text.
- Tick cost with every v1.7.0 module on (bench `KITS-ALL`): a Leaderboards `max`/`sum` submit is
  combined in memory and joins the save within 30 s (and on each store write, leave and shutdown)
  instead of one save transaction per call; Leaderboards visits a player only when a write, source
  read or fold is due; Streak re-evaluates online players once per day change instead of every
  60 s; Replication reuses a module's part of the state while nothing in it changed.

### Fixed

- `tools/net` no longer fails in roblox-core, where there is no `games/` folder: it only searches the
  roots that exist.
- `--help` and `-h` now print usage and exit 0 on every tool. `tools/build`, `dev` and `typecheck`
  answered "no such game", `make-module`, `make-migration` and `make-screen` reported an unknown
  option, and `tools/sync-projects`, `test-adopt` and `test-games-repo` ran instead of helping.

## [1.6.2] - 2026-11-12

UI polish and three fixes found by the first game built on StudWork. No new features; the module
API and the UI kit's props only grew.

### Fixed

- **The odds panel's region notice is never cut off.** It showed one line ("... You can") on phones
  while `TextFits` still reported true. Multi-line kit text (the notice, the luck/pity/mutation
  lines, Toast messages) is measured with `TextService` at its real width instead of relying on
  `AutomaticSize`, through the new `UI.WrappedText`.
- **Odds item names are readable on phones.** With the default text sizes, kit text never renders
  below the new theme metric `metrics.minTextSize` (default 11 real pixels, after the kit's
  responsive and Modal scales; a theme that raises it must raise its text sizes too). Names use a
  fixed size, wrap to 2 lines and end in "…"; tapping a name shows it in full under the row. Rarity
  badges and percentages keep their columns.
- **"Odds" appears once.** The default Odds screen, the sandbox, the new-game template and the
  override examples pass `title = false` to the `OddsTable` inside their window.
- **Buttons inside `UI.Modal` can be clicked.** The tap-blocking layer sat above the panel; the
  panel is now above it and the close button above both.
- **A Modal never runs off the screen.** Its content scrolls inside 88% of the screen height,
  computed in the content's own design pixels, instead of growing past the top and bottom edges.
- **The sandbox and the new-game template's odds window was blank.** Their ScreenGui used the
  default `ZIndexBehavior.Global`, so the Modal's backdrop covered the panel. They (and the override
  examples) use `Sibling`, like the UI kit's own ScreenGuis; `UI.Modal` warns once in a Global
  ScreenGui. **Games: set `ZIndexBehavior = Enum.ZIndexBehavior.Sibling` on any ScreenGui that
  renders `UI.Modal`.**
- **Item cards fit their size.** Long names clipped (scaled text in a box one line high); now they
  wrap to 2 lines with "…", the text rows keep readable sizes and the icon takes the space left
  (at least 120×160 design px for every optional row; a smaller card clips its contents).
- **Economy's client part loads**, so the coin counter is on the HUD again. Its definition never
  declared `client = "Economy"`. A test now checks that every kit module with a `client/` folder
  declares it. Games that registered `"Economy.currency"` themselves as a workaround can delete
  that registration.
- **Lune specs in a single-game project see the root `default.project.json`** also when the spec
  path is absolute, so a spec under `src/` can require `ReplicatedStorage.Game.*` with no copied
  project file. `tools/test-single-game` runs such a spec by discovery, relative and absolute path.

### Changed

- Theme default `metrics.text.min` (the smallest size scaled kit text may shrink to) is 14 design
  pixels, was 9; `TextFit.MIN_TEXT_SIZE` likewise. A tight custom label that only fitted at 9–13 px
  may need more room.
- `UI.Modal` content scrolls instead of the whole panel shrinking below the readable minimum
  (`ModalFit.minScale`). Content is laid out with a 12-px gap (the theme padding), was 8.
- `UI.Toast` no longer pops in from 60% scale (the scale would take its text below the minimum).
- `UI.OddsTable` rows are 48 px tall (was 36) and the name/badge/percent columns are 38/37/25%
  (was 42/33/25%).
- `UI.ItemCard` names and income use the theme's small text size instead of scaled text; the icon
  is sized from the space left. The Inventory screen's cells are 120×160 (was 96×128).

### Added

- Theme metric `metrics.minTextSize`; `UI.WrappedText`; `OddsTable` prop `title = false`; in the
  pure modules under `ReplicatedStorage.UI`: `ModalFit.minScale(tokens)`,
  `ModalFit.contentHeight(...)` and `ItemCardLayout` (module-api §22).
- A kit-wide text-fit check: `tools/lune/uifit/` (every UI component, four sizes, planted
  violations) and the Studio audit `tools/studio/ui-text-fit.luau`, which measures clipped text,
  text under the minimum size, blocked Modal buttons, Modals off screen and overflowing containers
  at desktop, small phone, large phone and tablet sizes (docs/manual-qa.md).
- The README shows real code under the banner: a minimal game config and a client using
  `StudWork.use`.

## [1.6.1] - 2026-11-11

Patch fixes and safety hardening from the v1.6.0 review. The module API remains additive.

### Fixed

- **Unknown gamepass ownership never becomes a guessed purchase result.** A purchase that needs
  a pending or failed pass lookup retries with nothing granted or recorded, even if its handler
  catches the error. Slow-lookup tests cover loading on time and safe receipt redelivery.
- **Undeclared legacy writes fail loudly in tests and Studio.** A bridge declaring
  `writesLegacyData = false` that writes through the legacy mock (including receipt-history
  writes) answers `NotProcessedYet` and logs the product, module, store and key. Studio compares
  the imported keys before and after the handler; failed reads fail closed. Live servers retain
  declaration-only checks, and warn once at boot with analytics `LegacyCodeLive` when bridges or
  legacy list entries remain. The adopted boot passes the mapped `StudWorkBoot.LegacyList`.
  Detection limits are stated in adopting.md §4.3 and known-issues O6.
- **Adoption guardrails:** the adopted marker is sticky across git history. Removing it or the
  legacy list cannot bypass lint or live-publish verification; missing/shallow history requires
  `--verify` to pass. Optional `tools/lint --anchor-remote` compares the baseline and marker with
  the remote default branch. Generated projects include full-history CI using it and the pinned
  framework toolchain. A history rewrite resets local anchors (documented).
- **Place-file safety:** `.studwork-from-place.json` records the original's name, path and SHA-256.
  `--strip-place` and `--from-place` refuse to overwrite its path or content regardless of name.
- **OddsTable:** rarity badges, item names and percentages scale/wrap within their columns rather
  than clipping on narrow screens. Theme token `metrics.text.min` supplies the minimum scaled
  text size. Rendered Studio checks cover desktop, small/large phones and tablet sizes.
- **Adopted client boot:** wait for initial replication before requiring the framework from
  ReplicatedFirst, preventing a partially replicated Framework from failing on a missing child.
- **Migration playbook:** clarify overlapping old Config mappings, leftover project-file remote
  instances, old item-uid references, game-owned paid rolls, formatting and notes from step 0.

### Changed

- **The default gamepass prefetch wait drops from 5 to 2 seconds.** Configure
  `GameConfig.shop.passPrefetchTimeout` (seconds, range 0–5); invalid values fail boot. Reason:
  a slow MarketplaceService unnecessarily held every join's save load for up to 5 seconds.
  Lookups continue in the background. `PlayerLoadTiming` records total/load/prefetch durations,
  pending lookup count and timeout status. `Shop.PASS_PREFETCH_SECONDS` remains as the upper bound.
- `ctx.shop.ownsPass` inside a transaction refuses unknown ownership rather than reading a failed
  lookup as not owned: purchases retry; other transactions error. This prevents correctness from
  depending on the prefetch timeout.
- `ctx.shop.legacyReceipts` accepts optional `checkDays` (positive days, default 90) for the window
  after `until`. After the window, very late old receipts grant normally. Imported receipt-id
  retention remains 90 days. Both cutover checklists explain the distinction.
- `tools/lint` rejects unknown arguments. `tools/publish --live` refuses when the adopted marker's
  history cannot be established. Empty `studwork-legacy.json` files stay mapped into adopted places.

## [1.6.0] - 2026-11-11

Agent-driven adoption of existing Roblox games, plus two framework requests (odds preview at any
luck, per-item luck). The module API only grows; `framework = "^1.3.0"` ranges still match.

### Added

- **Adopting an existing game** (`docs/framework/adopting.md`, the agent playbook
  `docs/agents/adopt-existing-game.md`, the copy-paste prompt `docs/agents/migrate-prompt.md`, and
  `AGENTS.md` at the repo root, an index for any coding agent):
  - `tools/adopt --audit <project|place> [...]`: a read-only static audit of a Rojo repo or a
    place file (DataStores and save libraries with their key patterns, purchases with what each
    product sells and where its history lives, remotes, leaderstats, UI, globals, shared stores
    across places), rated risks (`critical` / `high` / `medium` / `low`) and a numbered plan, in
    `studwork-adopt-report.json` + `.md`. Blink-generated files and vendored save libraries are
    skipped; product ids resolve through constant modules.
  - `tools/adopt --from-place <file> [--out <dir>]`: a Studio-only game's code containers become a
    Rojo project (the place file is never modified; the extracted scripts are recorded).
  - `tools/adopt --init <project> [--name] [--modules A,B|none] [--tag] [--url] [--dry-run]`: adds
    StudWork to an existing game (the `studwork/` submodule at a tag, `studwork.json` with
    `"adopted": true`, wrappers and hook, the game module `modules/<gameId>/` with server and
    client parts and a sim-boot spec, the boot scripts `studwork-boot/`, a minimal GameConfig with
    the audit's product ids when the game has none, a merged `default.project.json` that keeps
    every existing entry, and `studwork-legacy.json`).
  - `tools/adopt --verify <project>`: fails while anything unsafe for going live is left (a
    critical risk, an `onLegacyProduct`, a `purchases` legacy entry, a script left in or
    extracted from the place file that still uses DataStores or purchases, a stale `$path`).
    `tools/publish --live` runs it.
  - `tools/adopt --strip-place <project> [--extracted] [<instance path> ...]`: retires scripts
    left in a place file into `<name>.studwork.rbxlx` and repoints `studwork.json`; the original
    place is kept for rollback.
- **`ctx.data.importLegacy`**: a module imports its players' old saves once, at join, read-only
  (raw DataStore, ProfileService / ProfileStore, DataStore2 with Combine, or a map of sources), in
  one non-yielding transaction with the session lock re-checked; a failure kicks with nothing
  written. Optional `merge` for old saves changed after the import, `receipts` for old purchase
  ids, `itemTag` for imported items. Old stores are only ever read.
- **Purchase bridge** in Shop: `ctx.shop.legacyReceipts({ name, key, until? })` reads an old
  purchase-history store so an old receipt never grants twice; `_framework.legacyPurchases` keeps
  imported receipt ids (by age, 90 days); `ctx.shop.onLegacyProduct` runs an old product handler
  through Shop's duplicate checks in test places only.
- **Transitional guardrails**: `studwork-legacy.json` lists old files with the checks they still
  break (warnings, counts may only shrink against `legacyBaseline`, anchored to the adoption
  commit; `ProcessReceipt`, `special` and `packages` are never downgraded). The pseudo-check
  `style` (every old source, at init) skips selene and StyLua in `tools/lint` and turns
  `tools/typecheck` problems into warnings.
- `tools/test-migration`: runs every legacy import against synthetic sample saves
  (`tests/legacy/*.json`): field coverage, idempotence, failure kicks, partial saves, merge, items
  over the cap, sold fields and paid currencies; prints the import's failure reason and output.
  `tools/test` runs it in an adopted project.
- `tools/format [--check]`: formats with the core's StyLua config, over the files lint checks.
- `tools/test-adopt`: `tools/adopt --init` end to end on the three fixture games
  (`examples/legacy/legacy-example-a` place file, `-b` ProfileService, `-c` DataStore2), run by
  `tools/test`.
- Sim: sim players support leaderstats (`FindFirstChild`, `WaitForChild`, `Instance.new` Folder and
  value classes); `server:action(player, module, name, ...) -> (ok, result | reason)`;
  `{ legacy = "world" }` reads the World's mock DataStores as old stores.
- **Rarity / Compliance** (framework requests): `getOddsDetail(tableId, player?, luck?)` previews
  the odds at any luck; per-item luck (`discloseItem`, `clearItem`, `opts.item` on rolls, client
  `read.itemOdds`) for paid rolls whose luck belongs to one item.

### Changed

- `ctx.shop.ownsPass` never yields for a loaded player: every `products.passes` entry is looked up
  at join, before the save loads (a join can wait up to 5 s for MarketplaceService); inside a
  transaction an unknown pass errors instead of yielding.
- The `remotes` guardrail message points to module actions instead of the v1.2 `Core.Net.handle`.

### Fixed

- Economy: a currency listed in `currencies` can be granted without a `startingCurrency` key.
- `tools/test`: a test that never completes (a yield nothing resumes) fails with its reason after
  `STUDWORK_TEST_TIMEOUT` seconds (default 60); the run could exit 0 with no output before.
- The legacy reader treats an unpublished place in Studio ("publish this place to access
  DataStore") as no API access: the import is skipped for the session instead of kicking.

## [1.5.0] - 2026-11-11

Single-game projects. No module API change; `framework = "^1.3.0"` ranges still match.

### Added

- **Single-game projects** (`docs/framework/single-game-project.md`): a third project layout next to
  the core repo and the games repo. The repository root is the game and StudWork is the git
  submodule `studwork/`, pinned at a release tag. The layout is recognised by a committed
  `studwork.json` marker (`{"layout": "single-game"}`): `tools/_common.sh` exports
  `STUDWORK_LAYOUT`, and `tools/lune/Roots.luau` adds `Roots.LAYOUT`, `Roots.single`,
  `Roots.layoutOf`, `Roots.parentsFor`, `Roots.rootName` (`gameDirs` / `findGame` return the root
  game `"."`, with an optional layout argument).
- `tools/new-project <path> [--name] [--modules] [--url] [--tag] [--no-install] [--author-name]
  [--author-email]`: creates a complete single-game repo (git init, the `studwork/` submodule at a
  tag, the game scaffolded at the root with `$path`s into `studwork/`, `docs/design.md`, wrappers,
  hook, `.gitignore`, `.env.example`, `README.md`, `CLAUDE.md` for game agents,
  `FRAMEWORK_REQUESTS.md`, `tools/install`, and the first commit through the real pre-commit hook).
- `templates/single-game/`: the skeleton `tools/new-project` copies.
- In a single-game project every tool works with no game name: `tools/dev`, `lint` (the project's
  own Luau: every top-level folder and Luau file except `studwork/`, `.git/`, `.cache/`), `typecheck`, `test`, `build`
  (`build/<deploy.json name>.rbxl`), `publish --test|--live [--dry-run]` (stamps the root
  `deploy.json`; no `GAMES.md`; the clean-tree gate covers the whole project + `studwork/`),
  `framework-status`, `doctor`, `make-module <Name>`, `make-screen <Name>`, `sync-projects`, `net`.
  `tools/new-game` refuses with a pointer to `tools/new-project`.
- Guardrails (`packages`) in a single-game project: the `studwork/` pin (initialised, exactly at a
  release tag, no local changes), a `studwork` pointer staged with any other file is refused (except
  in the project's first commit), and a `game/*` branch must not move it; planted cases in
  `guardrails --self-test`.
- `tools/test-single-game [--keep]`: an end-to-end test of the mode against a local fixture remote
  (a tagged snapshot of the working tree); `tools/test` (no arguments) runs it after
  `tools/test-games-repo`, so CI does too.
- Specs: `Roots.spec.luau` (layout detection, the root game), `NewProject.spec.luau` (arguments,
  skeleton, template checks), `DeployStamp.spec.luau` (`tools/lune/DeployStamp.luau`: stamping
  without `GAMES.md`), `GuardrailsSingle.spec.luau`, and a `SyncProjects.spec.luau` case for root
  projects.

### Fixed

- `SyncProjects.relative(".", path)` no longer prefixes `../` for a project at the root.

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

[Unreleased]: https://github.com/RandyjCrowley/studwork/compare/v1.6.2...HEAD
[1.6.2]: https://github.com/RandyjCrowley/studwork/compare/v1.6.1...v1.6.2
[1.6.1]: https://github.com/RandyjCrowley/studwork/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/RandyjCrowley/studwork/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/RandyjCrowley/studwork/compare/v1.4.1...v1.5.0
[1.4.1]: https://github.com/RandyjCrowley/studwork/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/RandyjCrowley/studwork/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/RandyjCrowley/studwork/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/RandyjCrowley/studwork/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/RandyjCrowley/studwork/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/RandyjCrowley/studwork/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/RandyjCrowley/studwork/releases/tag/v1.0.0
