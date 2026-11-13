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

## v1.8.0 (quests, carry, companions, player and moderation kits)

Five kits, each designed against the official Roblox documentation linked in its entries. APIs
change: re-check these pages before relying on a limit. The framework gained only small generic
additions (`ctx.configValues`, two allowed services, `ctx.gameConfig.analytics`, the `CoreUIScale`
and `CoreEffectsGroup` player attributes); no framework code names a kit.

### v1.8.0: quests kit

- **Quests and Goals are two modules in one kit folder.** Goals is the first-session pointer and must
  work in a game with no quest system; Quests is the retention layer. Splitting them keeps each
  switchable (`modules`, `flag`) and lets Goals point at quests through Quests' public API only.
- **One reset boundary per game, on the framework clock.** Days and weeks are counted as Streak and
  Leaderboards count them: `floor((ctx.now() + utcOffsetHours * 3600) / 86400)`, weeks from
  `weekStartsOn`. A per-player local day would need the client's clock, which a player controls, and
  would let a server hop or clock change re-deal a set.
- **The daily set is dealt deterministically and saved.** The saved set is authoritative for its
  period; the seed (FNV-1a of user id, kind, period id, `poolVersion`, slot, reroll index; xorshift32
  draw over the eligible pool in id order) only re-creates it when no saved set exists (new period,
  or a crash rolled the save back). So rejoining, hopping servers or crashing can't fish for a better
  set or a free extra reroll.
- **Claim and grant in one `ctx.tx`.** The claim record (period/window, `done`, chain step) and every
  reward grant (`Economy` / `Inventory` / `Rarity` txApi, or the game's registered handler) commit
  together or not at all; the tx doesn't yield, one tx per player runs at a time, and the session lock
  gives one writer across servers. This is the same reasoning as receipt-safe purchases, without
  Robux.
- **Progress is batched, and `progress` never opens a transaction.** A busy game calls `progress`
  every frame; a save transaction per call would blow the tick budget. Non-completing increments stay
  in memory and fold into the section every `foldSeconds` (staggered per player), before any
  claim/reroll/deal, on leave and on shutdown. An increment that completes an objective flags the
  player and is folded on the next 1-second tick, not synchronously: the framework allows one
  transaction at a time and errors on a nested one, and games call `progress` from inside their own
  transactions (a crate tx, a Mail claim, a reward handler). `Goals.complete` queues the same way. So a
  crash loses at most `foldSeconds` of partial progress, or a completion from the last second.
- **Periods only move forward.** Each server's `os.time()` differs by a few seconds, so near the reset
  a player can hop from a server already on day D+1 to one still on D. A saved period id (and every
  saved period or window key) is only ever replaced by a larger one; a set saved ahead of this
  server's clock stays current. Otherwise the hop would re-deal day D from its seed and let its quests
  be claimed twice.
- **Both modules boot with no config.** `tools/new-game` and `tools/adopt --init` list every kit
  module by default, with no config section for the new ones (`tools/test-adopt` boots that game in
  the sim). So `daily.count` larger than the pool is an error only for a non-empty pool; an empty pool
  deals nothing.
- **Acknowledge objectives are the only client-driven progress.** A quest made only of `ack`
  objectives, or auto-claimed with one, is a boot error; `ackQuest` / `ackGoal` are rate-limited
  actions that never grant anything themselves.
- **Random rewards go through Rarity at luck exactly 1, free, with odds Quests discloses itself.** The
  claim passes `luck = 1` explicitly (Rarity's `nil` means the player's session luck). A quest claim
  is not a purchase and spends no currency, so Compliance treats the roll as free; a table Rarity
  counts as paid (`paid = true`, or a cost in a paid currency) is a boot error, because Rarity would
  treat any roll on it as paid and refuse restricted players. Rarity replicates odds only for tables
  with a cost or `luckDisclosed`, so Quests replicates `Rarity.getOddsDetail(table, nil, 1)` for every
  roll-reward table (`extra.questOdds`), and every roll reward chip on the board has an Odds button
  showing exactly those odds. PolicyService's `ArePaidRandomItemsRestricted` governs paid random items
  only (https://create.roblox.com/docs/reference/engine/classes/PolicyService); no quest reward
  involves Robux.
- **One beam, attachments under Terrain.** A Beam renders only when it and both attachments are
  descendants of Workspace (https://create.roblox.com/docs/reference/engine/classes/Beam,
  https://create.roblox.com/docs/reference/engine/classes/Attachment,
  https://create.roblox.com/docs/effects/beams); two attachments on `workspace.Terrain` need no extra
  parts. The pointer updates on a budget (`pointer.updateSeconds`, and only after half a stud of
  movement), and the edge arrow uses `Camera:WorldToViewportPoint`
  (https://create.roblox.com/docs/reference/engine/classes/Camera).
- **StreamingEnabled: point at what the client last saw.** A streamed-out instance is parented to nil
  on the client (https://create.roblox.com/docs/workspace/streaming), so a tag or path target can be
  missing. The client keeps each target's last known position, then a configured `fallback`, then hides
  the beam and keeps the pill. `ModelStreamingMode.Persistent` is documented as an option for a few
  small targets only, as Roblox recommends (same page; `Workspace.PersistentLoaded`:
  https://create.roblox.com/docs/reference/engine/classes/Workspace). The server doesn't walk the world
  for targets.
- **Gamepad focus only inside a screen the player opened.** The board sets
  `GuiService.SelectedObject` (https://create.roblox.com/docs/reference/engine/classes/GuiService) to its
  first Claim button when opened from a gamepad; the pill, tracker and edge arrow are never
  `Selectable`, so they can't steal the game's navigation. Reduce motion follows the framework's
  `CoreReducedMotion` attribute or `GuiService.ReducedMotionEnabled`.
- **Funnel steps through `ctx.analytics.funnel`.** The framework already logs each step once per player
  (`AnalyticsService:LogOnboardingFunnelStepEvent`,
  https://create.roblox.com/docs/reference/engine/classes/AnalyticsService); Goals adds no store of its
  own. Tags for targets use CollectionService
  (https://create.roblox.com/docs/reference/engine/classes/CollectionService).
- **Removed ids are pruned on load, not by migrations.** Quest and goal ids come and go with content
  updates; a migration per removal would be churn. `data.sanitize` has no config (`fn(section) ->
  section`) and an error in it kicks the player, so it only repairs shapes; the config pruning runs in
  each module's first tx on `onPlayerLoaded`. Quests' `done` ledger is never pruned, so a one-time
  quest removed and re-added can't be claimed twice; `retired = true` is still the clean way to stop
  offering one.
- **Returning players skip the first-session chain.** When a live game adds Goals, a player whose
  `goals` section is new but who has played before (`ctx.framework.sessions(player) > 1`) starts with
  the chain finished and logs no funnel steps, so the onboarding funnel counts new players only.
- **Event quests read events, they don't own them.** `ctx.events.schedule` allows one handler per event
  id, which belongs to the game, so Quests uses `isActive` and the framework's `EventStarted` /
  `EventEnded` signals. A hand-triggered event's window key is the start of its UTC day, so a server
  hop can't open a second claim (and a second trigger the same day doesn't reopen a claimed quest).

### v1.8.0: carry kit

#### Carry drives carried objects anchored, by CFrame, interpolated on the shared ticker

**Decision:** while carried, an object is anchored with `CanCollide` off.
- The server computes a clamped target from the carriers' validated positions at 10 Hz.
- It writes the object's CFrame (`PivotTo` for models) at `motionHz` (default 30) from
  `ctx.lifecycle.onTick`, which runs on Heartbeat, interpolating between the last two targets.
- On a drop the object is unanchored, then `SetNetworkOwner(nil)`. `CanCollide` stays `true` the
  whole time (never disabled by default) — fling protection comes from a collision group
  (`"CarryDropped"`, excludes characters only) assigned immediately, not a no-collide window.
  Once settled, the object is re-anchored.
- `AlignPosition`/`AlignOrientation` are not used.

**Why:**
- **Ownership:** anchored parts are always server-owned, so a client can never own a carried object.
  `SetNetworkOwner` errors on anchored parts, so it is called only after unanchoring.
- **No free fall:** an unanchored, non-colliding part driven at 10 Hz free-falls between writes (about
  1 stud per 0.1 s, and through the floor on a server hitch), and clients see 10 Hz steps.
  Interpolated writes on an anchored part do neither.
- **Determinism:** Align* constraints need a simulated body, which costs a physics step per object,
  and their settle time is non-deterministic. CFrame driving keeps the blend and clamp pure functions
  that the sims assert on.
- **Re-anchoring settled objects** stops characters from pushing or flinging them. A kill plane above
  `FallenPartsDestroyHeight` returns any object that falls out, so the engine never destroys it.

Docs relied on:
- network ownership: https://create.roblox.com/docs/physics/network-ownership
- AlignPosition: https://create.roblox.com/docs/physics/constraints/align-position
- AlignOrientation: https://create.roblox.com/docs/physics/constraints/align-orientation
- RunService: https://create.roblox.com/docs/reference/engine/classes/RunService
- Workspace (`FallenPartsDestroyHeight`): https://create.roblox.com/docs/reference/engine/classes/Workspace
- streaming: https://create.roblox.com/docs/workspace/streaming

#### Movement derives every check from server-observed positions and its own clock; no Humanoid state is an exemption

**Decision:**
- **Positions only:** every check derives from the character root positions the server observes. It
  never reads `AssemblyLinearVelocity` (client-set) and never treats a Humanoid state (`Seated`,
  `Climbing`, `PlatformStanding`) as trusted, because the network owner runs the state machine.
- **Clock:** time comes from the module's own monotonic clock (`os.clock`), not the ticker's nominal
  `dt`.
- **Speed:** a 4 s sliding window with a ping-aware lag allowance,
  `clamp(ping + 0.15, 0.25, 0.75)` seconds, floored at 0.6 s for the window and the teleport cap alike
  (an empty window must survive a 0.5 s freeze).
- **Teleports:** a per-sample cap sized for zero false positives, plus a descent bound derived from
  server gravity. A short teleport past a tagged volume is caught by an exact analytic path sweep.
- **Respawns:** the new character is compared with the server's spawn placement (or a later server
  move), so a respawn is not a free teleport.
- **Trust:** only a non-`log` response on an integrity check revokes trust. A `hazard`/`checkpoint`
  crossing never does, so at the defaults (`log`) Movement changes no gameplay.
- **Seats:** exempt only with a server-side `SeatWeld` to the root, then checked relative to the seat.
- **Climbing:** accepted only next to a `TrussPart` or a tagged climbable part.
- **Platforms:** measured relative to the tagged platform's server CFrame.
- **Server moves:** any server write to the root's CFrame opens an anchor, so other code (for example
  Plot's spawn `PivotTo`) needs no knowledge of Movement.

**Why:**
- A client owns its character's physics and Humanoid state. Only the replicated position is
  independent of what the client claims.
- The ticker's `dt` is nominal and bursts after a hitch.
- A per-sample speed rule without a lag term strikes real players on 300 ms connections, while the
  window absorbs a freeze-then-catch-up and still catches a sustained 1.5x.
- The design math was probed: 0 strikes for legitimate play with 0.5 s jitter spikes, and every
  planted cheat caught (`docs/framework/kits/carry.md` "Worked numbers").

Docs relied on:
- network ownership: https://create.roblox.com/docs/physics/network-ownership
- Humanoid: https://create.roblox.com/docs/reference/engine/classes/Humanoid
- `HumanoidStateType`: https://create.roblox.com/docs/reference/engine/enums/HumanoidStateType
- Seat: https://create.roblox.com/docs/reference/engine/classes/Seat
- `Player:GetNetworkPing`: https://create.roblox.com/docs/reference/engine/classes/Player
- raycasting: https://create.roblox.com/docs/workspace/raycasting
- WorldRoot (Blockcast): https://create.roblox.com/docs/reference/engine/classes/WorldRoot
- collisions (collision groups): https://create.roblox.com/docs/workspace/collisions

#### The carry kit reads the world through a kit-owned `World` adapter (a test seam), not a framework change

**Decision:**
- **What the adapter covers:** Carry and Movement read characters, casts, tags, seats, ping and the
  clock only through a `World` object.
- **Live adapter:** the module's `shared/World.luau`. It fetches services lazily, under `pcall`,
  never at load or in `init`.
- **Fake adapter:** `packages/kits/carry/tests/FakeWorld.luau`, scriptable, and counting the engine
  calls it receives.
- **Installing a fake:** specs call `Carry.useWorld` / `Movement.useWorld`, a documented test seam.
- **No harness change:** `Services.ALLOWED` and the harness are unchanged.

**Why:**
- **The harness has no world:** its Workspace is empty and it can't provide `CollectionService` or
  `RunService`, so the anti-cheat sims need injected geometry, latency and characters.
- **Nothing is special:** a kit-owned seam keeps the framework untouched, and any third-party module
  could do the same.
- **Default boots keep working:** lazy, `pcall`-guarded service access keeps "boot every module at
  defaults" (`test-adopt`, new-game) working under the harness, where the module simply idles.

#### Movement's casts use the engine's collision filter, and Carry gives characters their own group

**Decision:**
- Movement's wall sweep and ground cast set `RaycastParams.RespectCanCollide = true` and
  `RaycastParams.CollisionGroup` to the character root's own group (read on the server, refreshed
  with the ping), with every character excluded.
- Carry turns `CanQuery` off on a carried object (back on when it is put down), so a game's own
  raycasts don't hit it either.
- Dropped objects go to `"CarryDropped"`; for that group to exclude characters, the live adapter puts
  character parts still in `"Default"` into `"CarryCharacters"`.
- `Movement.active(player?)` says whether Movement is policing that player now. Carry uses the raw
  root under its own clamp while it is false (flag off), the same as with Movement absent.

**Why:**
- By default `Raycast`/`Blockcast` hit any part with `CanQuery = true`, including `CanCollide = false`
  parts, and filter by the params' group (`"Default"`), not the character's. Without the filter a wall
  sweep struck every player walking through a zone, a checkpoint or a carried object: invisible in
  Lune (the fake skipped non-colliding parts) and found live in Studio.
- A kill switch must turn a module off, not turn its sibling's trust model into "untrusted".

Docs relied on:
- raycasting: https://create.roblox.com/docs/workspace/raycasting
- RaycastParams: https://create.roblox.com/docs/reference/engine/datatypes/RaycastParams
- collisions (collision groups): https://create.roblox.com/docs/workspace/collisions

### v1.8.0: companions kit

- **Local cosmetic followers, authoritative equipment.** Equipment and capped bonuses belong to the
  server; clients animate only bounded copies of the replicated equipped set. No client position
  enters gameplay state. Direct `PivotTo` movement avoids physics assemblies for a cosmetic system.
  Roblox describes `AlignPosition` as force-driven and `AlignOrientation` as torque-driven; these are
  useful physical movers but unnecessary for this kit.
  [AlignPosition](https://create.roblox.com/docs/reference/engine/classes/AlignPosition),
  [AlignOrientation](https://create.roblox.com/docs/reference/engine/classes/AlignOrientation),
  [mover constraints](https://create.roblox.com/docs/physics/mover-constraints),
  [PVInstance.PivotTo](https://create.roblox.com/docs/reference/engine/classes/PVInstance#PivotTo).
- **No Humanoid or pathfinding.** Optional rigs use AnimationController and Animator, while rigid
  models use the same movement maths. Pathfinding computes routes around obstacles; cosmetic
  followers intentionally permit clipping rather than maintaining paths per equipped copy.
  [AnimationController](https://create.roblox.com/docs/reference/engine/classes/AnimationController),
  [Animator](https://create.roblox.com/docs/reference/engine/classes/Animator),
  [pathfinding](https://create.roblox.com/docs/characters/pathfinding).
- **Streaming can remove Workspace content.** Missing character roots skip rendering, missing ground
  uses an owner-relative fallback, and templates remain in ReplicatedStorage. No persistent-model
  requests or forced streaming settings are introduced. Atomic models are not a guarantee for new
  children added after replication.
  [Instance streaming](https://create.roblox.com/docs/workspace/streaming),
  [streaming techniques](https://create.roblox.com/docs/workspace/streaming/techniques),
  [ModelStreamingMode](https://create.roblox.com/docs/reference/engine/enums/ModelStreamingMode).
- **Icons and bounded pages; looks shared with Plot through a generic decorator.** The default UI uses
  icons and bounded pages. A ViewportFrame renders another model view; custom thumbnail UIs should
  bound their active previews. Companions reuse appearance functions with Plot through a generic
  decorator extension rather than introducing a reverse kit dependency. Tags on cloned art are not
  used for discovery, and no read-only tag property is assigned; tag operations use
  CollectionService methods if needed.
  [ViewportFrame](https://create.roblox.com/docs/reference/engine/classes/ViewportFrame),
  [viewport frames](https://create.roblox.com/docs/ui/viewport-frames),
  [CollectionService](https://create.roblox.com/docs/reference/engine/classes/CollectionService).
- **Bounded movement work.** One client driver, distance-dependent update rates and a default maximum
  of 30 clones bound movement work. Device render cost still depends on art, transparency and rig
  complexity.
  [Improve performance](https://create.roblox.com/docs/performance-optimization/improve).
- **Plot's decorator extension is the only cross-kit change.** Owned-copy removals already offer a
  public transactional hook; income already offers a public rate-factor hook. Neither framework
  internals nor other modules' save sections are needed. Luck stays in Rarity's disclosed public
  APIs; companions never introduce their own hidden roll modifier.

### v1.8.0: player kit

- **Durable global cap through `ctx.data.shared.update`, not MemoryStore.** A capped code's use count
  is kept with `UpdateAsync`
  (https://create.roblox.com/docs/reference/engine/classes/GlobalDataStore#UpdateAsync), not in an
  expiring MemoryStore (https://create.roblox.com/docs/reference/engine/classes/MemoryStoreService).
  Ambiguous reservations are retained forever, so availability can underfill after a crash but the
  cap is never exceeded. Callbacks must be pure and non-yielding, because retries may run them more
  than once.
- **Live promotion definitions through a generic `ctx.configValues.snapshot()`.** The framework gives
  modules experience configs without naming a kit and without direct service access. Experience
  configs (https://create.roblox.com/docs/production/configs) support global snapshots,
  `UpdateAvailable`/`Refresh`, stale snapshot retention and JSON values; values are not refreshed
  merely by receiving `UpdateAvailable`. The kit caches with a bounded refresh and entry size. The
  JSON value maximum is 100,000 characters and the kit caps payloads at 90,000; the official guide
  allows 1000 active configs (check the current limits table before choosing a payload cap).
  Propagation is eventual (the guide gives roughly 15 seconds to one minute for a normal immediate
  rollout); fake tests never claim real propagation.
- **Accessibility follows the engine's preferences.** Reduced motion and preferred text size come from
  `GuiService` (`ReducedMotionEnabled`, `PreferredTextSize`:
  https://create.roblox.com/docs/reference/engine/classes/GuiService,
  https://create.roblox.com/docs/reference/engine/enums/PreferredTextSize), quality from
  `UserGameSettings.SavedQualityLevel`
  (https://create.roblox.com/docs/reference/engine/classes/UserGameSettings), keyboard bounds from
  `UserInputService` (https://create.roblox.com/docs/reference/engine/classes/UserInputService).
  Automatic is not the actual current rendering quality, and the kit never tries to set Roblox's
  quality. Controls keep physical touch minimums under the combined responsive, user and modal
  scale; slider schemas render as exact-step touch controls.
- **Sound and UI scale preferences are generic player attributes.** `SoundGroup.Volume` multiplies a
  sound's gain (https://create.roblox.com/docs/reference/engine/classes/SoundGroup), so feedback is
  routed to an effects group and game music to a music group. The framework reads two attributes
  on the local player, `CoreEffectsGroup` (the effects group; existing feedback sounds are rerouted
  when it changes) and `CoreUIScale` (multiplied with the responsive scale; touch minimums stay in
  physical pixels), so existing scaled roots and sounds follow the player's choice without the
  framework naming a kit.
- **Promotion policy.** Roblox's promo offer rules
  (https://en.help.roblox.com/hc/en-us/articles/10549651908244-Promo-Offers-for-Virtual-Rewards)
  require experience-only virtual rewards with no Robux or real-world value, public redemption
  details and no exchange, and prohibit unique per-user promotion codes. Custom rewards need the
  author's catalog review.
- **Once per player, permanently.** Version 1 rejects an explicit `oncePerPlayer = false`. Every
  definition verifies a durable, immutable cap policy, including uncapped `limit = 0`. Ambiguous
  reservations never expire; pending records and sequences are never pruned; finalizing is
  token-idempotent. Public operation budgets include recovery and up to four backend calls per
  operation.
- **Catalog retirement is permanent** across deployments and rollbacks; only settled history can be
  pruned. Pending recovery has no catalog or flag eligibility prerequisite and grants nothing anew.
- **Settings revisions.** Settings uses owner-only authoritative revisions plus per-id request
  sequences and a separate optimistic draft state; a first-dirty timer prevents a save from being
  postponed forever. A migration confirms `saveAsync` before clearing legacy data.

### v1.8.0: moderation kit

- **Three modules, Admin at the base.** Refs can't cycle, so Admin names neither of the others;
  Moderation and Reports declare it optional and register their panel actions, tabs and the audit
  sink into Admin's extensions in `init`. Each module works alone with a documented fallback
  (permissions from `ServerConfig.<Module>.admins`, audit to `ctx.log`).
- **Bans are Roblox's `BanAsync`, universe-wide.** It evicts across servers, refuses rejoins and
  covers suspected alts by default (https://create.roblox.com/docs/reference/engine/classes/Players#BanAsync).
  A universe unban doesn't lift a place ban (https://create.roblox.com/docs/reference/engine/classes/Players#UnbanAsync), so the kit only bans universe-wide.
  `BanAsync` can fail (HTTP, throttling; no documented rate), so a failed ban kicks locally and goes to
  a shared pending list any server retries.
- **Ban messages are preset keys.** Roblox forbids handles and direct links in `DisplayReason` and
  asks for public rules and an appeal path (https://create.roblox.com/docs/players#message-guidelines,
  https://create.roblox.com/docs/players#ban-guidelines); presets plus a game-set appeal line make
  that the default. Free text is opt-in and filtered.
- **Group roles through `GroupService:GetRolesInGroupAsync`.** `Player:GetRankInGroup(Async)` is
  deprecated and returns only the highest public role; role ids are stable, ranks don't define the
  hierarchy (https://create.roblox.com/docs/reference/engine/classes/GroupService#GetRolesInGroupAsync,
  https://create.roblox.com/docs/reference/engine/classes/Player#GetRankInGroupAsync).
- **Cross-server actions through `ctx.data.messages`, not MessagingService.** MessagingService is
  best effort (https://create.roblox.com/docs/reference/engine/classes/MessagingService) and
  refused to modules; messages are durable and reach an offline player on the next load.
- **Text mute through `TextSource.CanSend`** (https://create.roblox.com/docs/reference/engine/classes/TextSource);
  the kit never reads chat text, which platform-integrated chat (required from May 2027) removes
  (https://create.roblox.com/docs/chat/platform-integrated-chat).
- **Own report queue.** No API opens Roblox's Report Abuse menu; `SetCore("PromptBlockPlayer")` is
  the closest flow (https://create.roblox.com/docs/reference/engine/classes/StarterGui#SetCore).
- **Automatic actions never ban by default** (`auto.permissions = warn, mute, kick`): a false
  positive in a heuristic must not cost a player their account access.
- **The panel's code ships in the server part** and is cloned into staff PlayerGuis only, so
  non-staff clients never receive staff UI or the action list.
- **The actor is required** (`by = Player | "server" | "console" | "system"`; `nil` raises). A
  forgotten argument must never mean "trusted": that would give any forwarded client request
  owner power with no rank check or limits.
- **Fail closed on rank.** A target outside this server gets its rank from
  `Admin.rankOfUserId` (users map, then group lookup); if that fails, the action is refused
  (`"unknown_rank"`), so a moderator can't act on an offline admin.
- **No hot shared keys.** `ctx.data.shared` has only `update`, so every "read" is a full write and
  `return nil` deletes. The audit is chunked per server (`a/<day>/<job8>/<seq>`, 100 entries) with
  a day directory and a small per-target index; pending bans and open reports are per-user keys
  found through sorted map indexes (`range`/`get` are reads). One global key per day or per queue
  would exceed the 4 MB value limit and the per-key write rate in a large game.
- **Pending entries carry `kind`, `seq` and a lease.** An unban replaces a pending ban in the same
  write, retries apply only the latest `seq`, and only the lease holder retries, so a late retry
  can't re-ban an unbanned player and an incident doesn't make every server call `BanAsync`.
- **Only transient `BanAsync` errors are retried** (`"failure for UserId"`, timeout, HTTP);
  anything else (banning disabled, bad input) fails at once, so nothing is "pending" forever.
- **Free text is filtered at submission or refused**, including private reasons (the raw text
  goes only to `BanAsync`'s `PrivateReason`); context and data-view strings must be keys. Staff are
  players too, and "staff only" is not an exemption from Roblox's filtering rule.
- **Reporter ids need `reports.reporters`** (owner, admin), and nobody sees reports about
  themselves or higher staff, so a reported helper can't retaliate.
- **Anti-cheat thresholds may live in `ServerConfig.Moderation.autoSources`**: everything in
  `config.*` replicates to clients.
- **Client requests are §9 actions**, not `handleEvent` events: actions are scoped per module (no
  global name clash) and `h:action` reaches them in specs.
- **Distinct success statuses.** `kick`, `mute`, `unmute`, `warn`, `serverBan` return `"done"`
  (applied in this server) or `"sent"` (queued through `ctx.data.messages`); `ban`/`unban`
  `"banned"`/`"unbanned"`/`"pending"`; `punish` returns the step and the inner status, and
  `(true, "sent", "sent")` for an absent target (the step is chosen where the save is). Callers
  can tell "done" from "will happen" without a second call.
- **`Admin.allow` counts, `Admin.can` doesn't, and each staff action is counted once.** The module
  API counts (`allow`); Admin's own request handling counts its built-in actions and a registered
  tab's fetch, and only checks the permission before a registered action or row action, whose
  `run` calls the module API with `by = staff`. Without that split one click would be counted twice
  against `actionsPerMinute`.
- **Role caps through `Admin.limitsOf(staff)`.** Moderation needs a role's `maxBanSeconds` and
  `maxMuteSeconds` but must not read Admin's config; a small read-only API keeps the boundary.
- **Every tunable number is config:** the audit sizes and rates
  (`audit.chunkSize`, `bufferMax`, `privateReasonMax`, `detailsMaxBytes`, `readSecondsPerStaff`,
  `readCacheSeconds`, `refusedEverySeconds`, `shutdownSeconds`), `crossServer.perTargetPerHour`,
  `pending.indexExpiryDays`/`pollSeconds`, `Reports.queue.maxOpen`/`indexExpiryDays`,
  `Admin.grant.max`/`currencies`, the panel's duration choices. `audit.maxPerDay` and
  `Reports.retentionDays` were dropped: chunked writes have no daily cap to enforce, and resolved
  reports live only as audit entries, so audit retention governs them.
- **`queue()` returns index summaries; `detail()` reads one report.** Reading every `r/t/<userId>`
  key to list the queue would be a full DataStore write per report (no shared `get`); the sorted
  map `range` is a read, and notes and reporter ids are read only for the one report a staff member
  opens.
- **A pending ban survives a store outage in memory.** If `BanAsync` and both pending writes fail,
  the status stays `"pending"` (the player is kicked and refused here, the audit notes
  `pendingUnsaved`) rather than `"failed"`: the ban was meant and is retried as soon as the store
  is back.
- **A messaged mute's end is absolute** (`now + seconds` at send): a delayed delivery shortens the
  mute rather than extending a punishment past what staff chose.
- **Retention sweep once per start and every 6 hours, under a lease** (`sweep` in the `pending`
  sorted map), so one server does the deletes and a quiet game still expires its audit.
- **Refused staff requests are audited** (once per (staff, action) per
  `audit.refusedEverySeconds`), like refused automatic actions: probing for powers shows up in the
  log without letting a loop flood it.
- **Trusted actors' text is developer text.** `"server"`, `"console"` and `"system"` pass text the
  game wrote, so it isn't filtered; only text from a staff Player goes through TextFilter. The page
  tells games never to forward player-typed text with a trusted actor.
- **Studio skips the rank rule.** In Studio everyone has `studioRole`, so every staff action would
  be `"outranked"`; the rule is skipped there and specced with `isStudio = false`.
- **Admin may use TextFilter itself** (optional dependency), with `registerTextFilter`
  as an override hook: announcements and free panel text work with Admin + TextFilter alone.
- **Role config merges over the defaults.** `config.Admin.roles` goes through the framework's deep
  merge like every config table: a game changes a field of a role without restating it (lists such
  as `permissions` replace).
- **`serverBan` and `unban` need `ban`**, and `history` returns a plain list of `HistoryEntry`.
- **Kit event `RunResult`, not `Result`.** The `special` guardrail refuses kit event names that
  appear in framework code, and the framework has a `Result` type.
- **Unknown rank fails closed everywhere.** `Admin.rankOf` answers 0 for a player
  whose group lookup hasn't finished, and Moderation and Reports used it as "not staff". Rather
  than change `rankOf` (frozen), Admin gained `rankOfChecked -> number?` (nil = unknown, never a
  group lookup); the rank rule refuses `unknown_rank` and the Reports viewer rule hides the report.
  The Reports viewer rule never spends `groupLookupsPerMinute` (in-server and cached ranks only),
  so a busy Reports tab can't starve staff role resolution.
- **No rank remembered from filing time.** An earlier version stored the target's
  rank with the report and used it when Admin didn't know the current rank; a player reported as
  rank 0 and promoted later then stayed visible to lower staff, and a claimer's stale stored rank
  let a lower rank override them. Reports now uses only the current rank (`rankOfChecked`): unknown
  hides the report and refuses the resolve override; the field is gone from records and summaries
  (`queue()` returns the documented `ReportSummary` fields only). Cost: with group roles, reports
  about players who left are hidden from staff once Admin's group cache expires (known issue
  O41); trusted code and the console still see them.
- **Caps unknown = no absent punish.** When `Admin.limitsOf` errors, an absent-target
  punish is refused (`"failed"`, audited) instead of being sent without caps.
- **Ghost drops re-check after the remove.** A sorted map has no conditional remove (an
  `update` returning nil cancels), so `dropGhost` removes only while the record is closed and then
  reads the record again: a submit writes its record before its index entry, so an entry removed by
  a racing submit is found and written back.
- **The Reports tab's reads per fetch are fixed:** at most two index `range` reads per
  fetch, page 1 starts a walk and later pages resume the staff member's walk for 30 s, so the cost
  of a page click doesn't grow with `queue.maxOpen` (no schema cap needed).
- **Audit reads are bounded.** Every `ctx.data.shared` read is an `UpdateAsync`
  write, so a day read that touched every server's chunk cost one write per server. A day read now
  touches the directory plus `audit.chunksPerRead` (4) chunks, paged; the cache is time-only; the
  Audit tab reads the store at most once per request. `ctx.data.shared.get` (proposed in module-api
  §24.3, not built) remains the real fix.
- **Only bans count toward `bansPerHour`.** `Admin.allow` gained an optional `action` argument
  (additive): unban, server ban and history check the `ban` permission without using the ban
  allowance.

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

### v1.7.0: fixes from the final review

- **Quiet hours reach offline recipients through the ledger, not a per-player record.** The
  recipient's UTC offset rides in their shared Notifications ledger entry (`o`): every ledger write
  made while they are online stamps it, and `setUtcOffset` and leaving refresh an entry that exists.
  No entry is created just to hold an offset: one per player who leaves (about 96,000 items over
  two days at 1,000 CCU with 30-minute sessions) would need many times the module's memory share. A
  recipient with no entry gets `quiet.defaultUtcOffsetHours`; the page says to set it to the main
  audience. A durable per-player record (`ctx.data.shared`) was rejected: it has no read without a
  write, and every send to an offline player would spend a DataStore write.
- **Notifications limit the player who caused a send** (`actor`, `limits.perActorPerDay`, counted in
  that player's save). The other limits are per recipient and per server, so a client-chosen
  recipient could have every target's daily send spent by one player.
- **A TextFilter re-display that misses the cache counts against the author's rate.** Otherwise
  text a client sends straight to `textFor` reaches `FilterStringAsync` with no bound. It is a
  bucket of its own (`perPlayerPerMinute`, apart from submissions): in one shared bucket, viewers
  re-displaying an author's text could leave the author `rate_limited`. `shown` isn't counted at
  all: its original was a counted submission, and its result is held per record for
  `cache.seconds` outside the LRU cache, so a record costs at most one filter per `cache.seconds`
  however many viewers ask (rate-limiting it blanked friends and private records in bursts). With
  `cache.seconds` under 60 that hold is no bound, so `shown` then counts against the `textFor`
  bucket.
- **The `textfilter` lint never clears a name.** Only TextFilter's return values are clean: filtering
  the text and then sending the original anyway is the likeliest mistake, and the old "clean from
  the next line" rule passed it. Handlers named by a function defined in the same file are scanned,
  plain or dotted (`handler = M.f`) and also wrapped in a call (`handler = guard(f)`: each argument
  naming a same-file function is taken as the handler, since a wrapper passes the wire values on),
  and every wire parameter is a source unless annotated only `number`/`boolean`.
- **`ctx.policy.allows` takes permission fields; `ctx.policy.restricted` takes restriction fields.**
  "Unknown" must read as the safe answer for both kinds: `false` from `allows` on a restriction
  read as "not restricted". Each call refuses the other kind, so the mistake is an error.
- **A test universe is trusted only once the live universe is listed.** A live universe written
  under `test` (hand-written config, no live list) made every live server `"test"` and turned
  `testOnly` flags on in live. Resolving to live (with a warning) was chosen over a boot error: it
  fails safe and doesn't stop a game whose deploy.json still has a placeholder live universe.
  `StudWork.start`'s `env`/`isStudio`/`placeId`/`universeId` options count only with an injected
  platform, for the same reason.
- **The census bucket is split across maps past 500 servers.** A sorted map is one partition, so
  keys split inside one map would add read cost without adding throughput; each shard `k > 0` is
  its own map. Below 500 servers nothing changes (one key, one get). The usage items stay single
  keys: their update answers the experience-wide total the memory budget needs. Shard 0 carries
  the shard count (the largest any of its writers uses) and is read first: a server's own count
  comes from its last reading, so a server started after the split would otherwise read only
  shard 0 and undercount for its whole life. The servers already holding a reading keep the count
  in shard 0 every bucket, so it survives churn without anyone reading all 16 shards.
- **Placeholders are named at boot as a log line, not a warning** (Badges id 0, Notifications
  `messageId = ""`): a game in development boots clean, and a placeholder left in is still visible
  before the first send.
- **Defaults:** the Badges award budget is 80% of Roblox's limit (room for other `BadgeService`
  callers); TextFilter's `shownMaxDays` is 7 (a string filtered under older rules isn't shown for a
  month).

### v1.7.0: fixes from Studio, dogfooding and the tick budget

- **Harness players are userdata by default.** In Studio, Notifications refused every real player
  because it checked `type(player) == "table"`; every spec passed because the harness's players
  were tables. `h:addPlayer` now returns a proxy whose `type` is `"userdata"` and `typeof` is
  `"Instance"`, so this class of bug fails in a spec. `instancePlayers = false` keeps tables for
  specs that need them.
- **Leaderboards combine `max`/`sum` submits in memory and save within 30 s** (and on each store
  write, leave and shutdown). One save transaction per submit made the all-modules tick cost about
  1.2 ms against a 0.94 ms budget. A server crash can lose up to 30 s of submits (known issue O13);
  `set` boards still write at once.
- **The tick budget is measured with every v1.7.0 module on** (`tools/bench` variant `KITS-ALL`,
  with a Leaderboards submit per player per tick). The old `KITS` variant stays for comparison.
- **The sandbox uses demo opt-in values** (`minSessions = 0`, `minSessionSeconds = 30`) so the prompt
  can be checked in a first Studio session; the kit defaults (1 session, 180 s) are unchanged.
- **Badges show a Studio preview toast** for an award recorded but not sent, so a game can check its
  UI in Studio; the `BadgeAwarded` signal still means Roblox confirmed, and live behaviour is
  unchanged.

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

- **The local test gate mirrors CI for paths (v1.7.1).** CI has no `$TMPDIR`, so specs that build a
  temp folder fell back to `<cwd>/.cache`; Lune's `process.cwd` ends in `/`, which made `//`, and the
  harness's prefix strip then left an absolute-looking `/.cache/...` that failed to load. macOS sets
  `$TMPDIR`, so every local gate passed while Linux CI failed. The harness now normalises both paths
  (`tools/lune/testkit/pathutil.luau`: collapse `//`, `.`, trailing `/`), the specs join through it,
  and `tools/test` always runs the runner self-test with `$TMPDIR` unset, a `<repo>/` cwd, a
  doubled-slash spec path and a relative folder argument with a trailing `/`, with or without path
  arguments.

- **make-migration reads a referenced `data.version` and maps `migrations/` itself (v1.7.1).** A
  game's save version is often a constant shared with its save code (`version = Save.VERSION`), which
  a pattern can't follow. The tool evaluates `module.luau` under Lune (the module's own folder is
  real; `game`, the framework and kit refs are inert stand-ins), reads `data.version` from the
  definition and rewrites the one number literal it comes from. A version it can't bump (a computed
  `Base.VERSION + 1`) is refused with nothing written, because a migration the module's version never
  reaches is worse than no migration; `--from <n>` is the explicit way through, with the bump left to
  the user. The bumped definition is read back from the planned texts before anything is written, and
  a `--from` that disagrees with a version the tool can read, or that leaves a gap after the last
  migration, is refused (a gap fails the boot). The game module is mapped as `GameModule.module` only, so its `migrations/` never reached
  the place: the tool now adds `migrations` next to whatever node maps the module in each of the
  game's project files (order-preserving JSON, so `tools/sync-projects` stays clean), and refuses a
  module no project maps before writing anything. A lint rule would only fire after an unmapped
  migration had shipped.
- **`--modules` puts every named kit in the game module's `dependsOn` (v1.7.1).** Naming a kit says
  the game needs it. Leaving it in `optional` (the template's default for the four v1.7.0 kits) gave
  no init ordering and an `isEnabled` guard the game doesn't need. A named kit the template doesn't
  refer to gets a ref line in the block's own style; a kit added only as another kit's dependency
  keeps the template's place.
