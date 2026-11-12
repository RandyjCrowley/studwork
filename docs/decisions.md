# Design decisions

Why StudWork looks the way it does. Organised by topic; each entry gives the decision and the reason,
and rejected alternatives where they matter. Open problems are in [known-issues.md](known-issues.md).

**History.** These decisions were made between v1.0.0 and v1.4.1. StudWork started inside a
monorepo next to the games built on it; it became its own repository before v1.4.0 and public in
v1.4.1. Superseded decisions are not kept here; the current behaviour is.

Fixed from the start: Luau `--!strict` everywhere, one Roblox experience per game, and one framework
reused by any number of games.

## Toolchain and libraries

Pinned versions (checked 2026-11-10). Contributors must keep these pins in sync with `rokit.toml` and
`deps/wally.toml`; changing a pin is a decision and belongs here.

| Need | Chosen | Version (pinned) | Install | Why / notes |
|---|---|---|---|---|
| Sync/build | Rojo | 7.7.1 | `rokit add rojo-rbx/rojo@7.7.1` | the standard; actively released |
| Packages | Wally | 0.3.2 | rokit | CLI last released 2023-06 but the registry is active and it is still the default. x86_64-only macOS binary: needs Rosetta 2 on Apple Silicon |
| Lint | Selene | 0.32.0 | rokit | |
| Format | StyLua | 2.6.0 | rokit | |
| Scripts/tests | Lune | 0.11.1 | rokit | runs tools and the test suite outside the engine |
| Networking IDL | Blink | 0.18.9 | rokit (`1Axen/blink`) | a CLI that generates committed Luau, not a Wally package |
| Type check | luau-lsp | 1.70.1 | rokit | `luau-lsp analyze` with Roblox definitions pinned to the same tag |
| Player data | ProfileStore | 1.0.3 | Wally `lm-loleris/profilestore` (server realm) | the upstream repo's own `wally.toml` publishes this name, so provenance is confirmed |
| State replication | Charm + charm-sync | 0.11.1 / 0.4.1 | Wally `littensy/charm`, `littensy/charm-sync` | |
| UI | React-lua (`jsdotlua/react`, `react-roblox`) + `littensy/react-charm` | 17.2.1 / 0.4.1 | Wally | react-lua is stable and used by Roblox; react-charm matches Charm 0.11 |
| Utilities | `sleitnick/signal`, `sleitnick/trove`, `evaera/promise` | 2.0.3 / 1.8.0 / 4.0.0 | Wally | Promise 4.0.0 is the final stable release and still the standard |
| Analytics | `AnalyticsService` | built in | — | |

Not used:
- **ByteNet** (the Blink fallback): Blink is maintained.
- **Jest-Lua**: needs a running engine, and its CLI runner has had no release since 2020. Pure logic
  is tested under Lune with a small Jest-style harness (`tools/lune/testkit/`) and a multi-server
  simulator (`packages/framework/test/sim/`); engine behaviour is checked with a Studio playtest
  checklist (`docs/manual-qa.md`). Revisit if an Open Cloud test runner becomes standard.
- **Vide** (the React fallback): not needed.
- **git-filter-repo** for the repo split: built-in `git filter-branch` did the job without an
  install.

## Repo layout

- **`deps/wally.toml`, not a root `wally.toml`.** macOS filesystems are case-insensitive, so Wally's
  fixed output folder `Packages/` *is* our `packages/` folder. Wally installs next to its manifest,
  so the manifest lives in `deps/` and installs to `deps/Packages` and `deps/ServerPackages`; every
  project maps those paths.
- **Generated Blink code is committed** so a build never needs Blink; regenerate with `tools/net`.
  Generated files are excluded from lint and format.
- **Specs live next to the code they test** (`*.spec.luau`); Rojo ignores them through
  `globIgnorePaths`.
- **`packages/framework` + `packages/kits` + `packages/ui`.** The framework is the runtime (boot,
  data, transactions, net, replication, purchases, compliance, theme). Kits are ordinary modules
  grouped by theme (`base`, `collection`, `economy`, `engagement`, `social`). See "Modules and kits".
- **One folder per module** (`<kit>/<Module>/`: `module.luau`, `server/`, optional `client/`,
  `shared/`, `net.blink`), mapped to `ReplicatedStorage.Modules.<Name>` and
  `ServerScriptService.Modules.<Name>`. Moves were done with `git mv` so history follows.
- **Project files are generated** (`tools/sync-projects`, checked by lint): every kit module times
  two entries times every project is too much to keep by hand. An example module is generated into
  any project that maps it.
- **One module discovery** (`tools/lune/ModuleDiscovery.luau`) serves the testkit, the simulator,
  `StudWork.test`, sync-projects and the guardrails, so the tree tests run against is the tree Rojo
  builds.
- **Examples, not games.** This repo holds `examples/sandbox` (with a `foundation-only` variant: the
  same place with `modules = {}`) and the override fixtures `examples/overrides/ov-a` … `ov-f`. Real
  games live in a separate games repo. Every tool shares one notion of "a game": a folder with
  `default.project.json` and `src/`; the testkit maps a spec to the nearest `default.project.json`
  above it, so examples and fixtures need no special case.
- **Generator templates are files** (`templates/module/`, `templates/migration/`, `templates/screen/`,
  `*.tmpl` so lint, tests and Rojo skip them).

## Configuration

- **Config is pure data** (hex colours, model names as strings, no Instances) so it validates and
  tests under Lune. Validation rejects NaN/inf and unknown ids; `StudWork.start` refuses to boot on
  an invalid config. The config schema supports enums, ranges and described keys.
- **Multi-currency from day one.** Currencies are a map and every economy call takes an optional
  currency (default: the primary currency). Tips, stars or event tokens need this, and adding it
  later would have been a breaking change.
- **Items earn from the plot by default** (`income.source = "displayed"`, or `"owned"`). A delivery
  game earns from delivered items, a shop game from what is on its shelf.
- **Plots are game-supplied models** tagged `CorePlot`, with slots carrying a `SlotId` attribute, so a
  game can target a specific slot.
- **Offline progress is game-defined.** `onReturn(player, secondsAway)` always fires (capped); the
  framework only pays automatically when `offline.autoPay` is on. A garden game, for example, turns
  it off and grows plants from its own data.
- **Plain Luau numbers** (exact to 2^53). Enough for the intended games; add a formatting layer if a
  game needs idle-game magnitudes.
- **Balance numbers belong to games**; reliability rails (retry counts, caps, backoff) have framework
  defaults. Game-own tuning goes in `src/shared/Config/Tuning.luau`.

## Modules and kits ("nothing is special")

- **A kit is an ordinary module.** Kits use only the public module API (`defineModule`, a scoped
  `ctx`, `StudWork.use(ModuleRef)`); anything a kit can do, a third-party module can do. The
  `special` guardrail fails if framework code names a kit, or a module reaches framework internals or
  another module's server internals; it derives kit names from every `module.luau` and `net.blink`,
  so a new kit is covered automatically.
- **The game is its own module** (`games/<g>/modules/<id>/`), added by the framework. Purchase
  handlers and gameplay get a scoped `ctx` like any module; `Main.server.luau` only builds the world
  and calls `StudWork.start`.
- **Finer modules**, each with its own data key (Economy, Upgrades, Rebirth, Plot, Inventory, Items,
  Rarity, Mail, Streak, Offline, Friends). Hard dependencies are explicit refs (Inventory/Rarity →
  Items, Upgrades/Rebirth → Economy, Plot → Inventory); everything else is an optional integration.
- **Inverted extensions.** When a module needs to act on another against the dependency direction,
  the module being acted on offers the hook (`onItemRemoved`, `registerKind`, `capBonus`,
  `displayedSource`), so writes never cross into a section the caller doesn't own.
- **Disabled modules error clearly** ("Rebirth is not enabled in GameConfig.modules") instead of a nil
  index.
- **Items exist only through `GameConfig.items`**, validated at boot. Registering items after start is
  a hard error, not a silent no-op, so odds are always disclosed for every rollable item.
- **`init` and `start` never yield.** Long work goes through `ctx.lifecycle.onTick` or a spawned
  loop, which keeps boot synchronous and fail-closed.
- **Server part factories:** a server part returning `{ new }` is built fresh per runtime, so two
  runtimes in one process (tests, the simulator) never share module state.
- **Boot internals are off the public table.** The runtime slot is written only by the framework's
  own boot code; an underscore escape hatch on `StudWork` would be exactly the back door the
  `special` rule exists to catch.
- **Shared helpers are owned, not reached into.** Rarity owns the tier list (`Rarity/shared`, pure,
  replicated); small utilities are duplicated rather than reaching into another module's server
  folder.
- **Kit event names are PascalCase action names** (`roll` → `Roll`) with a `STUDWORK_<MODULE>`
  remote scope, so actions bind by convention and no two modules share a remote.

## Data, sections, migrations and transactions

- **Per-module sections.** Each module owns one section of the save, with its own defaults, version,
  migrations and sanitizer. The framework keeps `_framework` (receipts, owners registry) and an
  owners registry: a section whose owner doesn't match fails boot unless the new module declares
  `data.adopts`, so an orphaned section is never silently adopted.
- **Migration failure kicks the player** ("We couldn't load your save safely. Please rejoin. Your
  progress is safe."), logs an analytics event, and never saves defaults over an existing save.
  Gaps in migration numbers are boot errors.
- **The v1.2 flat save is split once** into sections (`FrameworkSection.V12_MAP`). It stays in the
  framework because moving it into each kit would need every kit loaded to migrate any save.
- **Transactions are sealed handles.** `tx` has no `data` field; `ctx.section(tx)` is the only route
  to a module's own section. Only one transaction per player can be open on the call stack; a call
  needing another player's transaction errors (nested updates would be overwritten by the outer
  commit).
- **Reads are frozen views** in every environment, so an in-place write errors at the line that makes
  it. Committed sections are frozen too.
- **Commits share unchanged subtables** and views/replication rebuild only the changed path. Rule:
  nothing writes `_framework` every tick (see R23).
- **A stolen save session kicks at once.** If ProfileStore ends the session externally or a save
  finds the lock gone, the record is dropped and every save path on the old server writes nothing.
- **Cross-server shared store** (`ctx.data.shared.update(key, fn)`): one framework DataStore via
  `UpdateAsync`, keys namespaced per module, with retries.
- **Framework clock `ctx.now()`.** Kit code never calls `os.time()`, so time-based behaviour is
  tested on the harness and simulator clock.

## Purchases and receipts

- **Robux purchases never use a remote.** Paid rolls go through a developer product and the module's
  product handler; client roll requests only accept in-game currency.
- **Receipt handling is a transaction.** A product handler gets `tx` and writes through the same
  functions the rest of the module uses (grant currency, add items, a paid roll with pity), which
  queue their signals until commit; `tx.retryLater()` replaces "return false".
- **Effects run after the save is confirmed**, so a crash can't run them twice. If the buyer leaves
  before confirmation, the framework makes one more confirmed save and then runs them (R11 covers the
  rare case where that save fails too).
- **Shop owns `ProcessReceipt` exclusively** and claims it as the very last boot step. A lint
  guardrail (`purchases`) bans `ProcessReceipt =`, `Prompt*PurchaseFinished`, `DataStoreService` and
  `ProfileStore` outside the framework. A runtime check also warns, logs `ProcessReceiptHijacked` and
  reclaims, but the engine makes the callback write-only, so it only works under test (R18).
- **`paid:` vs `paidcur:` tags.** `paid:<id>` means obtained with Robux; such copies are kept on
  rebirth by default. `paidcur:<table>` means rolled with a paid currency: a paid random item for
  policy purposes but wiped by rebirth, since otherwise spending earned currency right before a
  rebirth would make items rebirth-proof. Tags are derived from the transaction; callers can't set or
  forge them.

## Compliance and paid-random odds

- **Fail closed on policy.** Paid rolls are refused for players with `ArePaidRandomItemsRestricted`
  until the policy is known; inside a purchase, policy-unknown retries automatically.
- **The check is bound to the roll.** Random sources register a `sample` function, and
  `ctx.compliance.roll` / `spendForRoll` are the only way to get an outcome; there is no separate
  "I checked" call to spoof.
- **Paying and rolling are atomic.** Paid currencies are declared in `GameConfig.compliance` and can
  only be spent through `spendForRoll` or a registered spender; boot fails if a paid currency has no
  spender. There is no "free" escape: a truly free reward just doesn't spend a paid currency.
- **Odds are always disclosed**, including any luck applied to a paid roll. Luck is a framework
  concept (per player, per table or all tables); a paid roll errors unless the exact odds were sent
  to the client. Erroring is deliberate: inside a purchase it means "not processed yet", so the
  player is never charged for undisclosed odds. Odds travel in replicated state, not new remotes.
- **Paid random copies can't be mailed** (the receiver's policy is unknown while they are offline)
  and are untradeable for restricted players.

## Network (Net and Blink)

- **Net owns every listener.** Blink validates wire types and ranges; Net drops players who left,
  rate-limits per player per event, then calls the single registered handler in a `pcall`. Rate
  limits are safety rails, not balance.
- **Game remotes go through the same Net**, with the game's own `{ rate, burst }`. Module actions
  declared as a bare function get a default of 4/s, burst 8.
- **Requests before boot is done are queued** and released after every module's `start`.
- **Lune and the simulator don't bind Blink output** (it needs the engine); tests drive actions
  through the same Net path minus the wire.

## Replication

- **Charm + charm-sync** carry a per-player replicated state. `data.replicate` is always an explicit
  field list, never a whole section.
- **Only changed sections are rebuilt**, using per-section versions that Data tracks (it knows which
  sections a commit touched). Replication remembers what it last sent each player; that is how a paid
  roll knows the odds were sent.
- **Module state is namespaced** under `state.modules.<Name>`. The flat v1.2 fields remain for
  compatibility (R25).
- **`DataChanged` is coalesced** to once per player per frame.

## Mail and gifts

- **A mailbox in the save.** A handler returning `false` means "can't accept now"; the message moves
  into the player's mailbox (default cap 500) and can be claimed later. Only thrown errors count
  toward dead-lettering (default 10 attempts, exponential backoff). Mail kinds starting with `core_`
  are reserved.
- **Gifts go through an outbox:** the item leaves the sender and the message is written in one save,
  sent after the save is confirmed with a fixed idempotency key, and re-sent until it succeeds. Saving
  before sending is what makes "never duplicated, never lost" hold across crashes; the receiver
  dedupes the key. Same-server gifts use the outbox too, because a direct transfer writes two saves.
- **Undelivered gifts are capped per recipient** (100) and returned to the sender after 14 days,
  because ProfileStore's queue drops the oldest message past 1000.
- **Gifts are never sent to an arbitrary user id from a client** (a typo would send an item into a
  save nobody loads).

## Theme and UI

- **Theme is config.** Colours, fonts, sounds and rarity tiers come from the theme; a module's
  `theme` may be a function of its config (Rarity contributes tier colours from its own config). The
  `theme` guardrail bans hex colours, `fromRGB` literals and asset ids outside theme/config files.
- **HUD widgets are registered** (`UI.registerWidget`); kits register their own (currency, mailbox
  badge) with stable ids so games can override them. The framework HUD only knows slots.
- **UI fits any screen and font:** modals scale to fit 92% × 88% of the screen; text fits any theme
  font. The framework's feedback names say `Tier`, the theme concept, not a kit name.

## Guardrails

- **Guardrails are lint** (`tools/lune/guardrails.luau`, run by `tools/lint`), with a `--self-test`
  that plants violations of each kind. They catch mistakes, not deliberate obfuscation (R26).
- Checks include: games don't edit the framework (`packages`), purchases (`purchases`), nothing is
  special (`special`), theme literals (`theme`), balance numbers in game code (a heuristic), modules
  required but not enabled, and generated project files being current.
- **Studio admin:** in Studio every player may use admin commands; live servers use
  `GameConfig.admins`.

## Games-repo mode

- **Games use StudWork as a submodule** (normally `roblox-core/`), pinned to a release tag.
- **Two roots, everything relative.** Tools take the project root from `STUDWORK_PROJECT_ROOT`
  (default: the framework itself) and the framework root from their own location; the framework must
  sit inside the project. Every path in committed files is relative, so Rojo, Lune and luau-lsp
  resolve the same paths on every machine, and a games repo needs only one-line wrapper scripts.
  Rejected: running tools from the framework with the games repo passed in (paths would cross repos
  and differ per machine), and a per-repo config file (one more thing to keep in sync).
- **Deps and toolchain come from the framework.** One `wally.toml`/`wally.lock` and one `rokit.toml`
  decide every version, so a game can't drift from the framework it was tested with, and bumping the
  submodule bumps both. Rokit only reads the `rokit.toml` above the working directory, so games mode
  links the pinned tools into `.cache/studwork-bin/` (V3). Rejected: a copied or symlinked
  `rokit.toml` (a second pin, and dangling before `submodule update`).
- **The pin is a lint guardrail:** submodule initialised, HEAD exactly a release tag, no local
  changes, and the pointer never mixed with game edits in one commit. A game is always built from a
  released, tested framework; `deploy.json` records which (`coreSha`, `coreTag`).
- **`test-sim` and `bench` stay framework-only.** A game's Boot spec already boots it in the
  simulator under `tools/test`.
- **The games-repo test builds a real submodule** from a snapshot of the working tree, so the pin
  check, stamping and the `protocol.file.allow=always` flow are exercised for real.

## Single-game projects (v1.5.0)

- **One repo per game is the default way to start** (`tools/new-project`): the root is the game,
  StudWork is the `studwork/` submodule pinned at a tag. The games repo stays supported for people
  who want several games under one pin. Everything is additive: core and games-repo behaviour is
  unchanged.
- **The layout is a committed marker file, `studwork.json` with `{"layout": "single-game"}`.**
  Rejected: guessing from folder names (a `studwork/` folder or a root `default.project.json` can
  appear in other layouts, and the answer would change while `tools/new-project` is half done), and
  a field in `deploy.json` (that file is the game's publish record and is rewritten by every
  publish; the layout is a property of the repo, read before any game is found). A separate file is
  visible to a fresh clone, CI and the hook, is trivial to read from bash (`grep`) and Lune, and has
  room for later settings. `tools/_common.sh` decides once and exports `STUDWORK_LAYOUT`;
  `Roots.luau` reads it and falls back to the same file check, so both sides agree.
- **`is_games_repo` keeps meaning "the core is a subfolder"** (true in both external layouts), so
  the toolchain links, the git shim and the framework pin apply to single-game projects without new
  code; `is_single_game` / `Roots.single` select the few differences (no game name, root paths).
- **The game's modules stay in `modules/<name>/`**, not a single `module/` folder: module discovery,
  `tools/make-module`, `tools/sync-projects`, the guardrails (`special`, `theme`) and the new-game
  template all use `modules/*`, and a game can have more than one module. One convention across the
  three layouts means the same template and generators.
- **The new repo's identity defaults to the running checkout's repo-local identity**
  (`git config --local user.name/user.email`), overridable with `--author-name/--author-email` or
  `STUDWORK_AUTHOR_NAME/STUDWORK_AUTHOR_EMAIL`; with none, git's global identity applies. Nothing
  personal is hard-coded in the generic tool, and the maintainer's checkout (whose repo-local
  identity is the public noreply identity) produces that identity by default.
- **The first commit goes through the real pre-commit hook.** It necessarily adds the `studwork`
  pointer together with the scaffold, which the staged check would refuse; in a single-game project
  that check is skipped only when the repo has no `HEAD` and no ref at all yet (nothing can be
  bumped in a root commit; an orphan branch in an existing project gets no exemption). Every later commit that stages the pointer with any other file is refused. Rejected:
  committing before enabling the hook (the scaffold would never be checked by the hook) and
  splitting the root commit (a pin-only commit fails lint: there is no game yet).
- **`--no-install` copies Wally packages from the running checkout** so the hook's tests can run in
  the first commit without network access (`tools/test-single-game` uses it); the default runs
  `tools/install`.
- **The template privacy spec lists no real names.** `NewProject.spec.luau` checks the
  files of `templates/single-game/` (rendered) for generic machine paths (`/Users/`, `/home/`, `.local`) only; names a
  maintainer must never ship (own projects, hosts, people) come from the env var
  `STUDWORK_PRIVATE_NAMES` (comma-separated) or the git-ignored `.private-names` file, and that part
  is skipped when neither is set. A list of private names in the repo would itself be the leak.
- **`tools/test-single-game` excludes `.gitmodules` from the no-absolute-paths check**: it records
  the `--url` the user chose (the public URL by default; the test passes a local fixture path).
- **Lint and guardrails in a single-game project cover every top-level folder and Luau file**
  except `studwork/`, `.git/`, `.cache/`, `.worktrees/` and `node_modules/` (the v1.5.0 review found
  that skipping `build/`, `Packages/` and hidden folders let a raw remote through in a folder the
  project could map). Deriving the set from `default.project.json` `$path`s was rejected: a file
  that isn't mapped today can be mapped tomorrow without anyone re-running lint.

## Publishing

- **`tools/publish` requires a test publish of the same build inputs before live.** "Same" means
  nothing under the game, `packages/` or `deps/` changed since, so committing the stamp doesn't block
  live forever. The API key goes to curl through a 0600 header file, never argv.
- **Endpoint:** `POST /universes/v1/{universe}/places/{place}/versions` (scope
  `universe-places:write`). Roblox now prefers the Assets API; revisit when this endpoint is retired.

## Versioning and releases

- **Semantic versioning.** A new capability is a minor release (games-repo mode was v1.4.0); fixes
  and repo changes are patches.
- **Tags are `vX.Y.Z`.** The framework was split out of the original monorepo with its history kept
  (`git filter-branch --index-filter`); earlier `core-vX.Y.Z` tags became `vX.Y.Z`, and v1.3.1 is
  exactly the last monorepo commit.
- **Games record the framework version they were built with** (`deploy.json`, `tools/core-status`).
- **Breaking changes wait for a major version** (for example removing the v1.2-shaped data, R25).

## v1.4.1 (public release)

- **The repository is public under the MIT licence.**
- **Internal build history stays out of the public repo.** Build reports, prompts and review notes
  from development were kept privately; this file and `known-issues.md` carry the decisions and open
  issues that matter to users.
- **Games-repo pre-commit hook fixed** (V1): git runs hooks with a relative `GIT_INDEX_FILE`, which
  broke the pin check's `git -C` calls on every commit. Games mode now clears git's hook environment
  before the pin check, and the games-repo test commits through the hook.
- **A root `CHANGELOG.md`** covers the whole repo; the framework changelog stays with the package.

## v1.7.0 (engagement, text, flags, localization)

Designed against the official Roblox documentation as it read on 2026-11-12 (each create.roblox.com
page below was read from its source in the public creator-docs repository). APIs change: re-check
these pages before relying on a limit.

- **Grouping.** Notifications, Badges and Leaderboards join Streak in the engagement kit
  (return-day and progress hooks); TextFilter joins the social kit (it exists because players
  show each other text). Environments/flags and localization are framework features, below.
- **Flags and environments are framework features, not a kit module.** The `testOnly` rule is a
  boot error, so it must run inside boot's config validation, before any module; flags are read
  by every module and by the UI on both sides; and `StudWork.flags` is a facade name, which a
  kit can't own without the framework naming a kit. It stays "nothing is special": modules reach it
  through `ctx.flags`, the same surface a third-party module gets, and kits use it only through a
  `flag` config key naming a game flag (a live kill switch).
- **Localization is a framework feature too.** The UI kit and the framework's own messages need
  strings whether or not any module is enabled, so the resolver lives in framework `shared/` and
  the UI kit. Modules add their English defaults through a new definition field (`strings`), the
  same for kits and third-party modules.
- **Neither framework feature appears in `tools/new-project --modules`.** That list is for
  `GameConfig.modules`; these are always on and inert until configured. The templates carry
  their config (`flags = {}`, `strings = {}`, the generated `Environments.luau`) with comments, and
  the sandbox shows both in use. Their pages stay under `docs/framework/kits/` next to the module
  pages (one page per v1.7.0 feature in one place), each opening with a line that says it is a
  framework feature, always on, not listed in `GameConfig.modules`.
- **Kit order and optional dependencies.** The new kits sit in `KitModules` ORDER after Streak:
  `Leaderboards`, `Badges`, `Notifications`, then the social kit with `TextFilter` after Mail.
  Optional dependencies don't change boot order beyond what the loader already does with
  `dependsOn`: a kit uses an optional module only through `ctx.isEnabled` and its public API from
  `start` on, when declared dependencies' APIs (hard and optional) are available whatever the
  order.
- **Placeholder ids are allowed and never sent.** A badge `id = 0` or a notification
  `messageId = ""` records and schedules like a real one, makes no Roblox call, and warns once per
  server, so a new game (and the sandbox) can list every module with defaults before the
  dashboard assets exist.
- **Environment = Studio, else a listed test place or test universe, else live.** An unlisted place
  counts as live, so a forgotten list can only switch test features off, never on. The test
  universe id is matched too, so the test experience's sub-places are test. The opposite mistake,
  the live id typed under test, would switch every `testOnly` flag on in live, so an id in both
  lists is a boot error and equal test and live ids in `deploy.json` fail `sync-projects --check`.
  (Design review: the reviewer's fix, taken as is.) The ids come from
  `deploy.json` (already the source of truth for publishing) through a generated, committed
  `Environments.luau`, so a game can't publish with ids its runtime doesn't know; `--check` catches
  drift. Rejected: reading `deploy.json` at runtime (it isn't in the place) and a manual list only
  (two copies of the same ids drift).
- **The live flag override is Roblox's experience configs (`ConfigService`).** It is the official
  remote config: server-only, per experience (so the test experience has its own values),
  published to servers in about 15 s to 1 min, with `UpdateAvailable`/`Refresh`. The framework
  reads it after boot (boot never waits), maps `flag_<name>` booleans onto declared flags, and
  refuses an override that would turn a `testOnly` flag on in live. Rejected: a DataStore
  document (needs polling budget and a tool to edit it) and an external HTTP service (a secret
  and an outage dependency). Player-targeted configs (experiments) are out of scope: flags are
  server-wide.
- **`serverOnly` hides a flag's value, not its definition.** `GameConfig` reaches every client, so
  a flag that must not be seen at all goes in `ServerConfig.flags`. On the client a `serverOnly`
  flag errors rather than reading as off: a silent `false` would make client code look correct
  while the server disagrees. Client flag values are presentation only; the server re-checks
  anything a flag gates.
  Sources: https://create.roblox.com/docs/production/configs,
  https://create.roblox.com/docs/reference/engine/classes/ConfigService,
  https://create.roblox.com/docs/reference/engine/classes/ConfigSnapshot.
- **Notifications are sent through Open Cloud from the game server, with the key from the secrets
  store.** `HttpService` can call Open Cloud's `CreateUserNotification` with an `x-api-key` header
  that must be a `Secret` from `HttpService:GetSecret` (only `x-api-key` and `content-type` headers
  are allowed; 2500 Open Cloud requests per server per minute, separate from the 500 HTTP limit).
  The framework wraps this as `ctx.openCloud`, so no kit touches `HttpService` or a secret value
  and tests fake it. Without the secret (or in a local playtest without a local secret)
  everything logs once and returns a reason. Rejected: the Creator Store "OpenCloud" Luau package
  the guide uses (an unpinned asset outside Wally that would have to be vendored and inserted
  into every place).
- **`ctx.openCloud` is deny-by-default and scoped per secret, module, method and path.** Roblox's
  HttpService allow-list for Open Cloud includes data store and ordered data store writes,
  memory-store flushes, config publishing and Luau execution, so a generic client would let any
  module bypass the session lock, the store budgets and hard rule 4. The allow-list lives in
  `ServerConfig.openCloud.secrets` (server-only, so clients can't see which secrets exist), names
  the modules that may use each secret, and takes single-segment `*` patterns only. On top, the
  store, memory-store, config and Luau-execution families are refused whatever the config says,
  naming the ctx surface to use. The owner still gives each key only the scope it needs
  (`user.user-notification:write` for notifications): the framework can't read a key's scopes, so
  the two fences together are the defence. (Design review: the reviewer's fix, with the table
  moved from `GameConfig` to `ServerConfig`.) The `purchases` lint check also makes
  `ConfigService`, `GetSecret`, `RequestAsync` and `PostAsync` framework-only in code, so the
  rule isn't only a convention; plain `HttpService` (JSON, GUIDs) stays allowed.
  Sources: https://create.roblox.com/docs/cloud-services/http-service,
  https://create.roblox.com/docs/cloud-services/secrets,
  https://create.roblox.com/docs/reference/engine/classes/HttpService,
  https://create.roblox.com/docs/cloud/guides/experience-notifications,
  https://create.roblox.com/docs/production/promotion/experience-notifications.
- **The opt-in prompt is never on join, and only at a moment the game names.** Roblox's prompt
  (`CanPromptOptInAsync` then `PromptOptIn`, client-only) is hidden from under-13s, from players who
  already opted in and for 30 days after it was shown; `OptInPromptClosed` reports no answer, so
  the experience can't know who opted in. The kit therefore never guesses opt-in state: it limits
  its own prompts (session time, sessions played, cooldown, a lifetime cap) and leaves delivery
  rules to Roblox. Source: https://create.roblox.com/docs/reference/engine/classes/ExperienceNotificationService.
- **Future-time notifications use a due list in MemoryStore sorted maps, polled by running servers.**
  Roblox has no scheduled send, and a notification can only go out from something that runs. The
  cost: no server running means a late or dropped (`staleAfterHours`) notification. Documented,
  not hidden. The protocol (design review, the reviewer's fixes, all taken):
  - *The claim moves the entry out of the due window.* A claim re-keys the entry's sort key to
    `now + leaseSeconds`, so later polls read past it: a stuck or failing head can't block the
    entries behind it.
  - *Retry state lives in the entry, not in a server's memory.* A failed attempt increments the
    entry's attempt count and re-keys it to its backoff time, so any server continues it and the
    lease only has to cover one attempt.
  - *The ledger counts a send only after Open Cloud accepted it.* Before sending, the server
    reserves the recipient in the ledger (a short reservation that expires with the lease); a 2xx
    turns it into a counted send, a failure clears it. A send that failed can no longer block a
    recipient for `minGapHours`.
  - *Limits that must hold for offline recipients live in the shared ledger.* `maxPerPlayer` and
    `cancelOnJoin` read the ledger's waiting keys, not the save, so `schedule` for an offline
    player is bounded too.
  - *Sharded and paced by the server count.* A sorted map is one partition (throttling starts at
    about 30,000 units a minute), so the due list and ledger are split into `schedule.shards` maps by
    user id, each poll reads one shard, and a server's poll interval grows with the server count
    from the framework census, keeping each shard near `pollsPerShardPerMinute` at any size.
  - *Memory is bounded by the module's share.* Entries are compact, `streakEnding` needs a streak
    of at least `minStreak`, scheduling is at most `maxAheadHours` (7 days) ahead, and every write
    counts against the module's MemoryStore memory share; when it is full, `schedule` says so and
    the streak reminder is skipped. A separate global entry count wasn't added: the share is the
    bound that matters.
  - *Launch data is untrusted.* `GetJoinData().LaunchData` can come from share links, so it is
    parsed strictly (`sw1:<templateKey>`, a configured template, at most 200 bytes), its signal is
    for attribution only, and `NotificationJoin` is counted at most once per player per day.
  Roblox allows one notification per user per day per experience, so `perPlayerPerDay = 1`.
  Templates must be personal and actionable and must not use false time pressure: the built-in
  "streak ending" send is only scheduled when it is true.
- **No PolicyService field governs notifications** (the fields are ads, paid random items, content
  sharing, trading, subscriptions, commerce, China, photo-to-avatar, endless content); age and
  region are enforced by Roblox's prompt and delivery. TextFilter does use `IsContentSharingAllowed`
  for text other players see, through a generic `ctx.policy.allows(player, field)` that fails
  closed. Source: https://create.roblox.com/docs/reference/engine/classes/PolicyService.
- **Badges: record first, send later; never twice.** `AwardBadgeAsync` works only while the player
  is in the server, can fail, and is limited to `50 + 35 x players` per minute; a player can delete
  a badge and be awarded it again. So the award is recorded in the player's save (in the
  triggering transaction where there is one) and sent from a background queue with backoff; a
  recorded badge is never sent again, and a pending one survives to the next session. Ownership is
  checked at join with `CheckUserBadgesAsync` (10 ids per call, `10 + 5 x players` per minute) and
  cached. Disabled badges (`GetBadgeInfoAsync().IsEnabled`) stay pending. `AwardBadgeAsync`
  returns false for a badge the player already owns, so a `false` triggers one ownership check
  and the join check covers pending badges too: a crash between the award and the save can't
  leave a badge retrying forever. Studio records awards in the Studio save but never sends them.
  Sources: https://create.roblox.com/docs/reference/engine/classes/BadgeService,
  https://create.roblox.com/docs/production/publishing/badges.
- **Leaderboards: all-time in OrderedDataStore, daily and weekly in MemoryStore sorted maps.**
  All-time scores must be durable (OrderedDataStore, integers only, pages of at most 100); periodic
  scores are disposable, and a sorted map per period (`<board>/<periodId>`, expiring after the
  period) makes the reset a property of the clock, with no reset job and no deletes. The top N is
  shared by every server and re-read from the store about once per `refreshSeconds` for the whole
  experience, by one server holding a short lease in a per-board MemoryStore item; every other
  server reads that item (one request unit). This answers both `GetSortedAsync`'s per-server
  `5 + 2 x players` limit and the experience-level list limit (`300 + 2 x CCU`), which many small
  servers each listing every board would exceed, and keeps one board's partition safe at any
  server count (each server's read interval grows with the census). Rejected: a MessagingService
  broadcast of the top N (another budget, and a lost message leaves a server stale with no way to
  ask). Writes are batched per player (`writeSeconds`) and **idempotent**: the player's save holds
  the authoritative total, so every write is `max(old, total)` (or a plain set), never an
  increment that a retry or a crash re-send could count twice. Periodic writes that can't beat the
  cached cut are skipped (`cutToTop`), periodic boards can be sharded (`shards`) when writes
  approach a partition's limit, and the module's writes count against its memory share. An exact
  rank beyond the top N isn't offered: neither store returns one without reading every entry.
  Sources: https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits,
  https://create.roblox.com/docs/reference/engine/classes/OrderedDataStore,
  https://create.roblox.com/docs/cloud-services/memory-stores,
  https://create.roblox.com/docs/cloud-services/memory-stores/sorted-map,
  https://create.roblox.com/docs/reference/engine/classes/MemoryStoreSortedMap.
- **Store access for kits goes through framework ctx surfaces** (`ctx.data.ordered`,
  `ctx.data.sortedMap`), scoped to the calling module by name prefix like `ctx.data.shared`. Hard
  rule 4 keeps `DataStoreService` in the framework, and the framework is the one place that can see
  the whole server's budget: ordered calls are refused (not queued) while their request type is
  near its per-server limit, and MemoryStore units are capped per server
  (`GameConfig.storeBudgets`), so a module can't starve player saves or another module. Store
  names carry a framework prefix (`SW/<Module>/<name>`) so they can't meet an adopted game's own.
- **MemoryStore memory is budgeted per module, from a census.** The memory quota
  (`64 KB + 1.2 KB x users`) is experience-wide and grows with concurrent users, but a due list grows
  with daily players, and a full quota fails every growing write in the experience: one module
  would stop all the others. No server can see the experience's usage or size, so the framework
  keeps a small census in its own sorted map: each server adds its player count to a time bucket
  and its modules' estimated write sizes to usage items bucketed by expiry hour, and reads the
  totals back once a minute. A module's growing writes are refused (`"memory_budget"`) past its
  share of the estimated quota (from the 8-day peak, matching Roblox's 8-day traceback), and all
  modules together past `1 - reserve`. The same census gives modules the server count, which the
  due list and the boards use to pace their reads. (Design review: the reviewer asked for a
  per-module share and a running estimate; the census is how a server gets an experience-wide
  estimate at all, and it also answers the scaling finding.) The per-server request-unit default
  dropped to `base = 20`, with the bound stated: at most a third of the unit quota while every
  server has a player.
- **Engine services reach modules through `ctx.services.get(name)`.** The framework already puts
  every engine service it uses behind its Platform table so specs run without Roblox; modules had
  no such seam. A small allow-list (Badge, Text, User, Localization services, Players) is
  returned live as-is and replaced by fakes in the harness; services that have a framework surface
  (DataStore, MemoryStore, Marketplace, Http, Messaging, Config, Policy) are refused with the
  surface to use.
- **TextFilter filters by audience and never returns unfiltered text.** `FilterStringAsync` then
  `GetNonChatStringForBroadcastAsync` for text everyone sees, `GetNonChatStringForUserAsync` per
  viewer for friends-only or own text; a failure means "don't show it". Roblox can only filter
  while the author is in the server, so the kit hands callers a save record with the broadcast
  string for display while the author is away (for at most `shownMaxDays`, since stored text should
  be filtered when it is retrieved) and keeps the original for re-filtering.
- **The original text never leaves TextFilter.** It is kept in TextFilter's own save section in
  the author's save (not replicated, bounded per author), and the record callers keep holds only
  an id, the context, the time and the broadcast string. The reviewer proposed keeping the
  original in the record under a field the caller must mark `serverOnly`; that still relies on
  every caller getting it right, while this way a record replicated by mistake leaks nothing. The
  lint check also flags a whole filter record reaching a sink, so displays go through `shown`,
  which applies the viewer and age rules. Each submission is filtered once, fresh (Roblox asks for
  one call per submission); the cache only serves re-display. `TextFilterContext` is a hint that
  doesn't change Roblox's result. Player text is never logged or sent to analytics. The lint check
  is a same-function heuristic: honest about what it can't follow (tables, other modules); its
  sinks include events to the author's own client, shared and sorted-map/ordered writes and
  notification params.
  Sources: https://create.roblox.com/docs/reference/engine/classes/TextService,
  https://create.roblox.com/docs/reference/engine/classes/TextFilterResult,
  https://create.roblox.com/docs/ui/text-filtering.
- **String keys with English defaults, translated by Roblox's translators, falling back to
  English, never blank.** `Translator:FormatByKey` errors when no table has the key, which is the
  normal "untranslated" case, so it runs in `pcall` and falls back to the English default.
  Labels keep `AutoLocalize` on and show English when no keyed translation exists, so automatic
  text capture and automatic translation work exactly as for any game text; keyed manual
  translations win where a game provides them. The format syntax is Roblox's (`{name}`, `{1}`), so
  a key's English text can be pasted into a localization table unchanged. The no-hard-coded-English
  rule is a lint check on the framework, UI kit and kit client code only, not examples or games:
  games may hard-code their own text, and the sandbox uses keys by convention. Keys built from
  config get their English defaults from `strings = function(config)`, the same pattern as
  `theme`. The template maps `src/shared/Localization/*.csv` into `LocalizationService` from v1.7.0
  (Rojo turns each CSV into a `LocalizationTable`), checked in Studio before the release, so a
  game can ship keyed translations without extra setup. The player's own-row colour of the
  leaderboard component is a base theme token, so the UI kit doesn't depend on a kit.
  Sources: https://create.roblox.com/docs/reference/engine/classes/LocalizationService,
  https://create.roblox.com/docs/reference/engine/classes/Translator,
  https://create.roblox.com/docs/production/localization/localize-with-scripting,
  https://create.roblox.com/docs/production/localization/automatic-translations.
- **Store request cap and errors.** The MemoryStore request-unit cap is one per server
  (`base + perPlayer x players`), shared by all modules; only memory has per-module shares. The
  census costs about 3 units per server per cycle, not 2 (an `update` is a read and a write). An
  error raised inside an `update` function (ordered or sorted map) raises in the caller, like the
  other caller errors, and does not return `false`; a function returning nil cancels the write.
  A server with 0 players has 20 units a minute, about 3 notification sends a minute (known
  issue).
- **Nothing in this release calls a real Roblox service in tests or while building it.** Every
  service above has a fake under `StudWork.test.fakes`; what only a live experience can show
  (delivery, throttling, real filter output, ConfigService propagation) is listed per page under
  "Not verifiable offline".

## v1.6.2 (UI polish and game-found fixes)

- **Text has a floor in real pixels, `metrics.minTextSize` (default 11).** `text.min` alone was a
  design-pixel floor, and the Modal's fit scale (0.665 on a small phone) multiplied it to about
  7 px. 11 px is about the smallest size still read comfortably on a phone. Modal no longer shrinks
  past `ModalFit.minScale`; tall content scrolls instead. `text.min` rose to 14 so the responsive
  minimum scale (0.85) keeps scaled text above 11.
- **Multi-line text is measured, not auto-sized.** In Studio the region notice laid out as one line
  inside the Modal/Panel AutomaticSize chain while the same label alone wrapped correctly, and
  `TextFits` stayed true. `UI.WrappedText` measures with `TextService:GetTextBoundsAsync`; the Modal's
  scroll height is set from its measured content for the same reason.
- **Long names truncate after two lines instead of shrinking.** A readable fixed size with "…"
  beats a full name at an unreadable size. The odds table shows the full name on tap (odds are a
  disclosure); an item card is a summary and doesn't.
- **`UI.Modal` requires a Sibling ScreenGui and doesn't try to work under Global.** Under Global the
  backdrop must sit above the game's other UI while a game's children default to ZIndex 1, so no
  ZIndex choice works for arbitrary content. The kit's ScreenGuis, the template and the examples use
  Sibling, the Modal warns, a spec checks the shipped clients, and the close button stays above the
  backdrop so a Global window can at least be closed.
- **The text-fit check has two halves.** Lune can't render React, so `tools/lune/uifit/` checks the
  source patterns (no AutomaticSize wrapping outside WrappedText, minimum sizes through the scale
  chain, two-line truncation only with a way to see the full text) and ties each fixture to the
  source it models. `tools/studio/ui-text-fit.luau` measures the real engine at four sizes. Both were
  shown red on v1.6.1; the real game flow is still checked by hand (manual-qa), since a game's own
  ScreenGui settings caused the blank odds window that every surface check passed.
- **TextScaled sizes are real pixels.** The engine applies `UITextSizeConstraint` after UIScale, so
  scaled labels (rarity badges, percentages, panel titles) don't grow on large screens. Left as is
  for this patch (known issue U2).

## v1.6.1 (fixes from the v1.6.0 review)

- **The join waits for gamepass lookups at most `GameConfig.shop.passPrefetchTimeout`** (default
  2 s, was a fixed 5 s), then loads the save. Not in parallel: Data marks the player loaded inside
  `data.load`, so a wait after it would let actions and receipts run before the PlayerLoaded
  handlers. Correctness never depends on the wait: `ownsPass` inside a transaction never guesses
  (a purchase retries with `pass_unknown`, any other transaction errors). A parallel load needs a
  Data "loaded but gated" step (later).
- **Kits that pcall a `capBonus` keep counting a failed bonus as 0.** Outside purchases that is the
  refusing direction (a lower cap refuses an add or a trade), never an over-grant, so Inventory
  wasn't changed (known-issues O5).
- **`writesLegacyData` is checked where it can be.** Test mocks report writes (an observer on the
  mock only; the live reader stays read-only). Studio compares the imported keys before and after
  the handler, because real DataStores can't be intercepted. Live is declared only (a boot warning
  listing every bridge and its flag, plus `--verify`). The `legacyReceipts` history store is
  not exempt: a bridge declared read-only must not mutate its deduplication history either.
- **The late-receipt window is `legacyReceipts.checkDays`** (default 90).
  `_framework.legacyPurchases` pruning stays a fixed 90 days because it belongs to the import
  (adopting.md §4.1), not to the history store.
- **The adopted marker is sticky, anchored in history.** Any commit reachable from HEAD whose
  `studwork.json` said adopted keeps the project adopted for lint and publishing; dropping the flag
  ("graduating") needs `tools/adopt --verify .` to pass. Any commit rather than the first add:
  adoption may come after the first commit and the file can be re-added. Only a history rewrite
  drops it, which `tools/lint --anchor-remote` (in the project CI template) catches against the
  remote default branch. Tools read local refs only and never fetch.
- **A place file is "the copy" by recorded content, not by name.** `.studwork-from-place.json`
  records the original's name, path and SHA-256; the adopt tools refuse to write a file with that
  path or content.
- **The v1.6.0 bench figure (0.866 ms/tick) was noise.** Alternated runs give v1.5.0 0.779 and
  v1.6.0 0.792 ms/tick (medians of 7, fully overlapping spreads, identical allocations); no per-tick
  code changed between them.

