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
  exempt: recording a receipt there is what old handlers do, and it isn't the save.
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

