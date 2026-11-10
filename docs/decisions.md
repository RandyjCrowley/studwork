# Decisions

Why core looks the way it does. Newest decisions are appended; superseded ones are marked, not deleted.
Fixed by the user (not revisited here): Luau `--!strict`, one repo, one Roblox experience per game,
core reusable by unlimited games.

## Toolchain and libraries (checked 2026-11-10)

| Need | Chosen | Version (pinned) | Install | Check |
|---|---|---|---|---|
| Sync/build | Rojo | 7.7.1 | `rokit add rojo-rbx/rojo@7.7.1` | release 2026-10-02, active |
| Packages | Wally | 0.3.2 | rokit | CLI last released 2023-06 but the registry is active; still the default. x86_64-only macOS binary → needs Rosetta 2 on Apple Silicon |
| Lint | Selene | 0.32.0 | rokit | release 2026-10-01 |
| Format | StyLua | 2.6.0 | rokit | release 2026-10-10 |
| Scripts/tests | Lune | 0.11.1 | rokit | release 2026-10-21 |
| Networking IDL | Blink | 0.18.9 | rokit (`1Axen/blink`) | release 2026-09-19, active. CLI tool, not a Wally package: it generates committed Luau |
| Type check | luau-lsp | 1.70.1 | rokit | release 2026-09-27; `luau-lsp analyze` + Roblox definitions pinned to the same tag |
| Player data | ProfileStore | 1.0.3 | Wally `lm-loleris/profilestore` (server realm) | upstream repo's own wally.toml publishes this name, so provenance is confirmed |
| State replication | Charm + charm-sync | 0.11.1 / 0.4.1 | Wally `littensy/charm`, `littensy/charm-sync` | release 2026-10-01 |
| UI | React-lua (`jsdotlua/react`, `react-roblox`) + `littensy/react-charm` | 17.2.1 / 0.4.1 | Wally | react-lua last release 2024-12 (stable, used by Roblox); react-charm matches Charm 0.11 |
| Utilities | `sleitnick/signal`, `sleitnick/trove`, `evaera/promise` | 2.0.3 / 1.8.0 / 4.0.0 | Wally | RbxUtil active 2026-08; Promise 4.0.0 is the final stable release (2022), still the standard |
| Analytics | `AnalyticsService` | built in | — | |

Not used:
- **ByteNet** (Blink fallback): not needed, Blink is maintained.
- **Jest-Lua**: requires a running Roblox engine; its CLI runner `run-in-roblox` has had no release
  since 2020. Pure logic is tested under Lune with a small Jest-style harness
  (`packages/core/tests/harness.luau`). Engine behaviour is verified with the Studio MCP playtest
  checklist instead. Revisit if an Open Cloud Luau-execution test runner becomes the standard.
- **Vide** (React fallback): not needed.

## Repo layout deviations

- **`deps/wally.toml` instead of a root `wally.toml`.** macOS filesystems are case-insensitive, so
  Wally's fixed output folder `Packages/` *is* our `packages/` folder. Wally always installs next
  to its manifest, so the manifest lives in `deps/` and installs to `deps/Packages` and
  `deps/ServerPackages`. Every game project maps those paths.
- **Generated Blink code is committed** (`packages/core/server/Net/Generated.luau`,
  `packages/core/client/Net/Generated.luau`, `packages/core/shared/net/Generated.Types.luau`) so a
  build never needs blink; regenerate with `tools/net`. Excluded from lint/format.
- **Spec files live next to the code they test** (`*.spec.luau`) so each Phase 1 agent owns its
  tests inside its own folder. Rojo ignores them through `globIgnorePaths`.

## Interface choices (Phase 0)

- **One facade, both sides.** `require(ReplicatedStorage.Core)` works on server and client.
  Server namespaces are real tables on the server and error on the client; `Core.Client` is the
  reverse. `Core.start(config)` is called once per side.
- **Multi-currency from day one.** `PlayerData.currency` is a map; every Economy call takes an
  optional trailing `currency` (default `balance.primaryCurrency`). Example Shop tips/stars and event
  tokens need this; adding it later would have been a breaking change.
- **Items earn from the plot by default.** `balance.income.source = "displayed"` (Example Courier:
  delivered items earn; Example Shop: evidence shelf) or `"owned"`. Economy derives item income itself
  from `PlayerData.displayed` / `inventory`; `addIncomeSource` is for extra game-defined sources.
- **Plots are game-supplied models** tagged `CorePlot`, with BasePart slots carrying a `SlotId`
  attribute. `Plot.display(player, uid, slotId?)` lets a game target a specific slot (Example Shop's
  evidence shelf = slots it names, e.g. `shelf01`).
- **Per-game data** lives at `PlayerData.game[gameId]` with defaults, a version and migrations in
  `GameConfig.data`; `Data.getGame/updateGame` (Example Shop star rating, Example Garden waterers).
- **Offline is game-defined**: `Offline.onReturn(player, secondsAway)` always fires (capped by
  `offline.capSeconds`); core only auto-pays when `offline.autoPay` (Example Garden turns it off
  and pays growth from its own visit data).
- **Inventory transfer** is in core (`Inventory.transfer`, `Actions.gift`) with a policy check, for
  Example Gifts gifting/trading. Offline/cross-server delivery uses **`Core.Mail`** (added to the
  given interface; ProfileStore `MessageAsync`).
- **Rarity roll takes `luck` and returns `(ItemDef?, RollInfo)`** instead of a bare ItemDef:
  callers need to know why a roll failed (restricted player, full inventory, unknown table) and
  whether pity fired. Example Collector maps its clean-run meter to `luck`. Paid rolls pass
  `{ paid = true }` and are refused for `ArePaidRandomItemsRestricted` players (fail closed until
  the policy is known).
- **Upgrades added as a core namespace.** The sandbox loop is "collect → earn → upgrade → rebirth";
  every shortlisted game has level-based upgrades, so `Core.Upgrades` with config-driven cost
  curves avoids five copies.
- **Robux purchases never use a remote.** Paid rolls go through a developer product and
  `Shop.onProduct`; `RequestRoll` only accepts tables with an in-game currency `cost`.
- **Config is pure data** (hex colours, model names as strings, no Instances) so it validates and
  tests under Lune. `ConfigValidate` rejects NaN/inf and unknown ids; `Core.start` refuses to boot
  on an invalid config.
- **Rate limits live in `core/server/Net`** (anti-spam safety rails, not balance). Net owns every
  Blink listener, rate-limits per player per event, then calls the single registered service
  handler; Blink validates wire types/ranges first.
- **Signals** are sleitnick/signal instances typed by `Types.CoreSignals`; `DataChanged` is
  coalesced to once per player per frame.
- **Big numbers**: plain Luau numbers (doubles, exact to 2^53 ≈ 9e15). Enough for the planned games;
  if a game needs idle-game magnitudes, add a formatting/scientific layer then.
- **Studio admin**: in Studio every player may trigger events (agent E implements), live servers use
  `GameConfig.admins`.

## core-v1.1.0 (hardening before the games)

User decisions (implemented as written):
1. **Migration failure kicks the player** with "We couldn't load your save safely. Please rejoin.
   Your progress is safe.", logs an analytics event, and never saves default data over an existing
   profile.
2. **Rebirth keeps Robux-bought items by default** (`ItemDef.keepOnRebirth`, nil = keep copies
   whose `source` starts with `paid:`). Fixes L2.
3. **Core is modular** (foundation + `GameConfig.modules`).
4. **Each game records its core version** (`deploy.json` `coreVersion`/`coreCommit`,
   `tools/core-status`, `GAMES.md` "Core" column).

Contract choices (Phase 0, core-contract-v1.1):
- **Module split as proposed**, with Items as its own module (Inventory and Rarity require it).
  The code argued for these hard dependencies: Inventory → Items (ItemDef lookups), Rarity →
  Items, Upgrades → Economy (spend), Rebirth → Economy (cost), Plot → Inventory (it displays owned
  copies). Everything else is an optional integration guarded by `ctx.isEnabled`: Economy uses
  Rebirth/Upgrades multipliers and Items income only when on; Offline autoPay, Streak rewards
  and Friends' co-play multiplier need Economy only when configured (ConfigValidate enforces it).
  Mail has no module dependency (it rides Data's ProfileStore, which is foundation).
  `income.source = "displayed"` requires Plot.
- **Manifest in a pure module** (`shared/Modules.luau`): module specs, boot order and the public
  function names per namespace. The facade builds frozen tables from it (M7), and the loader and
  ConfigValidate use the same `Modules.resolve`.
- **Disabled modules are present but erroring**, not nil: `Core.Rebirth.rebirth()` errors with
  "Rebirth is not enabled in GameConfig.modules" instead of a nil-index crash, and code that
  captures `Core.Rebirth` before `Core.start` keeps working.
- **Receipt-safe purchases (M4) use a transaction object.** The prompt's shape
  `(data, receiptInfo) -> ()` got a third argument, `tx: PurchaseTx`, because a Robux grant usually
  needs core logic (currency rules, inventory cap, a paid roll with pity) that must write into the
  same `data`. `tx.grant/addItem/roll` call ctx-only `*Into` functions that write into the
  transaction and queue their signals until it commits. `tx.retryLater()` replaces "return false".
- **`paid:` means "obtained with Robux"**, random or not: `tx.addItem` tags `paid:<product>`. Such
  copies are kept on rebirth and (conservatively) untradeable for paid-random-restricted players.
- **Nested `Data.update` for the same player errors.** With working-copy semantics (L6) a nested
  update would be overwritten by the outer commit; failing loudly is safer than merging.
- **Per-section versions live in Data** (`Data.sectionVersion`, ctx-only) so Replication (M2) can
  reuse unchanged sections; Data, not Replication, knows which sections a commit touched.
- **M7 data ownership:** Rebirth runs registered reset steps inside its single update (Upgrades
  resets levels, Plot drops displayed slots); Inventory no longer writes `displayed` (Plot clears
  it on `ItemRemoved`); Rebirth no longer requires `Upgrades/UpgradeMath`.
- **No new Blink events:** odds travel in `ReplicatedState.odds` via `StateSync`.
- **Phase 1 file ownership deviations from the prompt:** L7 (sanitize logging) moved from agent E
  to agent A because `Data/Sanitize.luau` is in A's folder. `games/_sandbox/src/client/Main.client.luau`
  belongs to agent B (the sandbox must show server odds, M1); the rest of `games/_sandbox/` is E's.
  `core/server/init.luau` and `core/client/init.luau` (boot code) go to E with
  `core/shared/init.luau`, since the module loader lives there.
- **`paid:` vs `paidcur:` (review N5).** `paid:<id>` = obtained with Robux (paid table, Shop
  `tx.roll`/`tx.addItem`): kept on rebirth by default. `paidcur:<table>` = a roll priced in a
  `balance.paidCurrencies` currency: a paid random item for Roblox's policy (odds shown, policy
  check, untradeable for restricted players) but wiped by rebirth, otherwise spending earned Coins
  right before a rebirth would make items rebirth-proof.
- **Effects of a Robux grant run after the save is confirmed** (agent A), not at commit: a crash
  can't run them twice; the cost is that they are dropped if the save fails and the player leaves
  (known issue N9).
- **Phase 2 review: 0 Critical/High.** Fixed N2, N5, N7, N10 before the tag; N1/N3/N4 and the lows
  are in `docs/known-issues.md`. N1 must be fixed before Example Gifts relies on Mail.

## core-v1.2.0 (finishing the platform)

Contract choices (Phase 0, core-contract-v1.2). All additive; one behaviour change (Mail `false`).
- **N1 mailbox, stored in PlayerData.** A handler returning `false` means "can't accept it now"
  (full inventory is a capacity condition, not a failure). The message moves to
  `PlayerData.mail.box` in one Data.update and is then `processed()` in ProfileStore, so core owns
  it: `Mail.pending(player)` lists it (replicated as `ReplicatedState.mailbox`, HUD badge
  "Mailbox (N)", `Core.Client.onMailbox`), and `Mail.claim(player, id)` re-runs the handlers
  (client: `Actions.claimMail` → `RequestMailClaim`). No time limit; `mail.mailboxCap` (default
  100) bounds the save size: beyond it the message stays queued in ProfileStore and is offered
  again next session. Rejected alternative: leaving held messages unprocessed in ProfileStore
  (no listing without our own index, and ProfileStore never re-offers them in the same session).
  Before v1.2 `false` counted as a failure; no game shipped, so the meaning changed in place.
- **Only thrown errors count toward dead-lettering.** `GameConfig.mail = { maxAttempts,
  backoff = { base, factor, max }, mailboxCap }`; defaults 10 attempts, 30 s × 2^n capped at
  900 s (≈ 75 min of retries in one session), attempts persist across sessions. These are
  reliability rails, so core has defaults (unlike balance numbers).
- **Gifts to anyone go through a mail outbox** (`Inventory.sendGift`, ctx-only
  `Mail.sendInto(tx, ...)`): the item leaves the sender and the message is written to
  `PlayerData.mail.outbox` in ONE Data.update, sent after commit with a fixed idempotency key,
  and re-sent on the sender's next load until MessageAsync succeeds. That is what makes "never
  duplicated, never lost" hold across crashes: the item and the message can't be separated, and
  the receiver dedupes the key. Copies from paid random sources (`paid:`/`paidcur:`) can't be
  mailed: the receiver's PolicyService answer is unknown while they are offline (fail closed).
  Mail kinds starting with `core_` are reserved (`core_gift`).
- **N3: re-send odds** (it is cheap: one table build per registration batch). Items gets a
  ctx-only `onRegistered` hook; Rarity rebuilds and re-replicates the shared odds and every
  player's luck-adjusted odds. No CLAUDE.md "register before start" error rule was needed; a
  softer recommendation was added (rule 14).
- **N4: luck is a core concept now.** `Rarity.setLuck/getLuck` (session-only, per player, per
  table or all tables); `roll` with `luck = nil` uses it. `getOddsDetail(tableId, player?)`
  includes the player's luck when the table has `luckDisclosed = true` (`OddsDetail.luck`).
  A paid roll with effective luck ≠ 1 errors unless `luckDisclosed` and the odds with exactly
  that luck were **sent** to the client: Replication remembers the state it last handed to
  StateSync per player (`ctx.sentReplicated`), which is reliable and ordered, so "sent" is as
  close to "received" as the server can know without an ack round-trip. Erroring (not failing
  softly) matches the prompt: it is a game bug, and inside a Robux handler an error means
  NotProcessedYet, so the player is never charged for a roll with undisclosed odds. Currency
  rolls (RequestRoll) check the rule before spending.
- **Games' remotes go through core (`Core.Net.handle`, foundation).** The guardrail "remote
  handlers must go through core's validated Net" needed something to go through: Net now listens
  to a game's Blink server event, drops left players, rate-limits per player with the game's
  `{ rate, burst }` and pcalls the handler. Added "Net" to `Modules.FOUNDATION` (service
  `server/GameNet`).
- **N6 fixed:** legacy ids are `legacy-<kind>-<second>-<fnv1a(canonical payload)>`.
- **N8 fixed for game code:** in Studio the facade's `Data.get`/`getGame` return frozen copies
  (`Data/ReadOnlyView`, cached per section version), so an in-place write errors at the line
  that makes it. Live servers return the live table (no cost); core services keep the live
  table. Done through `service.facade` overrides in the facade builder. Not covered:
  `Data.onLoaded` handlers still receive the live table (documented).
- **N9 fixed (analytics only):** `Receipt.forgetPlayer` returns the dropped entries and Shop
  logs `ProductPurchased` for them at leave; the grant itself is persisted by the session-end
  save. Game `tx.after` effects for a player who left are still dropped (they target a player
  who is gone). If the session-end save also fails, the next server re-grants and the event is
  counted twice; we accept a rare double count over a guaranteed miss.
- **Guardrails** live in `tools/lune/guardrails.luau`, run by `tools/lint` with a
  `--self-test` that plants one violation of each kind. "Game edits packages/" is checked by
  branch convention (`game/<name>` branches may not change `packages/` since `main`) and by
  staged-change mixing; the core owner can bypass with `GUARD_ALLOW_CORE=1`. The number check
  is a heuristic (balance calls with literals >= 2, balance-named assignments); game-own numbers
  go in `src/shared/Config/Tuning.luau`.

Phase 1/2 decisions (merge, playtest, review):
- **RequestGift never mails to an arbitrary user id** (agent A had added that fallback): a typo or
  fake id would send the item into a profile nobody loads. Cross-server gifts to other users are a
  game-server call to `Inventory.sendGift`.
- **Same-server gifts go through the outbox when Mail is on** (review R2): `Inventory.transfer`
  writes two profiles that save separately, so a crash between the saves duplicates or loses the
  item. `RequestGift` uses `sendGift` (a save, then delivery on the receiver's next save: seconds,
  not instant); `transfer` stays the no-Mail fallback and a server API.
- **The outbox saves before it sends** (agent A): a commit is only in memory, and sending first
  would let a crash restore the item AND deliver it.
- **mailboxCap default 500** (was 100, review R1). The decision above said a message beyond the
  cap "stays queued in ProfileStore"; ProfileStore's queue is capped at 1000 and drops the oldest,
  so a larger box keeps gifts out of it. Still open for receivers who never log in (known issue R1).
- **Paid-currency-priced tables count as paid** in `rollInto` unless `opts.free = true` (review R4,
  `RollOptions.free` added): rule 11 and the policy block no longer depend on the caller passing
  `paid`.
- **An all-table luck never reaches a paid roll on a table without luckDisclosed** (review R5):
  otherwise a luck potion for free rolls made every Robux egg purchase error until it expired. A
  luck set for exactly that table still errors.
- **UI.Modal scales its panel to fit 92% x 88% of the screen** (playtest): the odds modal's title
  and close button were off-screen at UIScale 1.73.
- **tools/publish: "same commit" means same build inputs** (agent D): live is allowed when the
  test record is HEAD or nothing under `games/<name>` (except deploy.json), `packages/` or `deps/`
  changed since; otherwise committing the stamp after `--test` would block `--live` forever. A test
  dry run unlocks only a live dry run. The key goes to curl through a 0600 header file, never argv.
- **Publish endpoint kept:** `POST /universes/v1/{u}/places/{p}/versions` (Beta, scope
  `universe-places:write`), checked 2026-11-10; Roblox's guide now prefers the Assets API (broader
  scope). Revisit when the universes endpoint is retired.
- **Scaffolds trimmed by hand:** `tools/new-game --modules` copies the full template loop; for
  games without Upgrades/Rebirth the client buttons and the rebirth goal were removed so lint
  (modules guardrail) passes. Scaffolds keep the sandbox loop otherwise (no gameplay code).

## core-v1.3.0 (framework restructure)

Phase 0 step 1-2 review of the drafts against the v1.2 code (`Modules.luau`, `Context.luau`,
`Types.luau`, `Net/init.luau`, `Replication/init.luau`, `Data/ReadOnlyView.luau`):
- **`philosophy.md`: no changes.** Every default and guardrail it lists matches the code
  (`Types.RarityTier`'s 7-tier union, `BalanceConfig`'s module sections, the N8/N9/N4 guardrails).
- **`module-api.md` §0: no changes.** Checked each row against the real v1.2 mechanism it
  replaces, including the three the prompt called out: Replication's per-player `SectionCache` +
  `sent` tracking (§10's `ctx.replicate.sent` is the same mechanism, renamed), Net's
  `PendingQueue`/`PENDING_CAP` pre-start queue (§3's boot step 6 matches `Net.start()` draining
  it), and `Data/ReadOnlyView.luau` (N8, §6's `ScopedData.get` frozen view). Mail's outbox
  (`MailInternal.sendInto`) and Rarity's luck registry (`setLuck`/`getLuck`) are both already
  covered by §0's Mail and Rarity rows.
- **§17 open questions answered and revised in place** (marked `(revised: ...)`):
  keep `ItemDef` in the framework (item-agnostic; Collection only owns and validates the tier
  list); finer modules (today's 11) plus `Kits.<Name>` bundles; per-module Blink is workable and
  scales linearly; `StudWork.use` typing needs a generic signature, no fallback accessor; the
  compliance-at-commit check uses an internal `Tx` flag only Compliance sets and Shop reads, the
  same pattern as `tx.after`; the v1.2→sections field mapping is complete, write and test the
  `_framework` migration in step 4. (The runtime facade was renamed `Core`/`Framework` →
  `StudWork` by the user directly in the drafts partway through this review; the first pass of
  this entry committed under b8de7d3 landed against the pre-rename file and was clobbered by the
  rename before the §17 answers were saved — redone here against the renamed, settled text, no
  content change beyond the name.)
- **The independent design-review subagent (Phase 0 step 3)** ran against the stale,
  pre-rename/pre-revision draft because of the above race; its findings are about substance
  (missing Data API shape, compliance-roll binding, cross-module section writes, etc.), not the
  naming, so they stand and are being worked into the next module-api.md revision rather than
  re-run from scratch.

### Design review findings folded into module-api.md (Phase 0, after step 3)

Saved the review to `(internal build report, not public)` (wasn't in the repo). Per
the user: fold in all Critical and High, plus Medium where the fix is small, taking the stricter
option where it conflicts with convenience, since philosophy.md's guardrails already prefer
strict. Every fold-in is marked `(revised: design review <id>)` in `module-api.md`.

- **C1** (no Data API, whole-profile access reachable): `StudWork.use` only accepts a `ModuleRef`;
  Data/Compliance/Net/Replication/Shop/Policy are framework internals with no public facade at
  all, only scoped `ctx` fields (§4).
- **C2** (compliance check not bound to the actual roll): `registerRandomSource` takes a `sample`
  function; `ctx.compliance.roll`/`spendForRoll` are the only way to get an outcome — no separate
  "I checked" call exists to spoof (§14).
- **C3** (pay and roll splittable across transactions; `opts.free` escape): `paidCurrencies` moved
  to top-level `GameConfig.compliance`; a paid currency can only be spent through
  `compliance.spendForRoll` (spend+roll atomic); `opts.free` dropped entirely — the stricter
  option, since a truly free reward just doesn't spend a paid currency (§14).
- **C4** (purchase handlers/game code have no way to get a scoped `ctx`): the game's gameplay code
  is its own implicit module (`games/<g>/modules/<gameId>/`), not a free-standing
  `Main.server.luau`; `ctx.shop.onProduct` replaces `StudWork.use(Shop).onProduct` (§7).
- **H1** (`tx` not actually opaque): `tx` is a sealed handle with no `data` field; `ctx.section(tx)`
  is the only route (§5.1).
- **H2** (frozen read views Studio-only in v1.2): every module's own-section read is frozen in
  every environment, not just Studio, flagged for the §17 Q6 performance re-check (§6).
- **H3** (cross-module writes against the dependency direction: Plot/Inventory, Mail/Collection):
  formalised "inverted extensions" — the module being acted on offers the hook
  (`Collection.onItemRemoved`, `Mail.registerKind`), using the same `ctx.section(tx)` binding
  mechanism already in §5.1, just entered from the other side (§8, §16).
- **H4** (`ProcessReceipt` hijackable): Shop claims it exclusively in the last boot step, a lint
  rule bans other assignment, and — per the user, beyond the review's own suggestion — the
  framework also polls for a runtime replacement and reasserts itself (§7.1).
- **H5** (orphaned module section can be silently adopted by an unrelated module): `_framework.
  _owners` registry, boot error on a key/owner mismatch unless `data.adopts` is declared (§6).
- **M1** (cross-player writes inside an open transaction commit immediately): only one tx per
  player open on the call stack; a call needing a different player's tx errors (§5.1).
- **M4** (every game hand-rolls policy-unknown retry): `compliance.roll`/`spendForRoll` retry
  automatically inside a purchase transaction (§14).
- **M5** (the `paid:`/`paidcur:` tag is optional, so a caller can omit it): Collection's `addInto`
  derives it from the transaction; callers can't override the prefix (§14).
- **M6** (`data.replicate = true` sends a whole section, contradicting §2's own example):
  `data.replicate` is always an explicit field list; fixed in §10 and the §18 example (§10).

**Deferred** (documented instead of fixed, per the user's "say why" instruction):
- **M2** (no cross-module "handoff" migration mechanism): genuinely needs new design (read another
  module's old section once during migration, version-bump both sides), not a small fix, and
  nothing in this round needs it — every v1.2 field maps to exactly one new section (§17 Q7
  already confirmed the mapping is 1:1). Revisit if a future round needs to move a field between
  modules after both already shipped.
- **M3, item-registration half** (v1.2's N3 `Items.onRegistered` re-sending odds after boot):
  **not deferred as a silent gap — made a hard error, per the user.** Items exist only through
  `GameConfig.items`, validated at boot (§12); there is no `register`-style call in v1.3 at all,
  so an attempt to add an item outside `GameConfig.items` errors immediately ("items must be
  declared in GameConfig.items; registering items after start is not supported in
  core-v1.3.0") instead of silently no-op'ing or partially working. Listed under Breaking in
  `packages/core/CHANGELOG.md`. Full post-boot registration (with Compliance re-disclosing odds
  before the item is rollable) stays out of scope for a later version — that part is still
  deferred, just not silently.
- **L1–L3** (gamepass handlers outside a transaction, non-atomic two-player transfers, module-name
  vs. Rojo-folder-name mismatch): left as Phase 1/2 implementation and test items, not module-API
  design changes; tracked in `docs/known-issues.md` once Phase 1 starts.

### User conditions on the fold-in (approved, before freezing core-contract-v1.3)

1. **M3 item-registration half is a hard error, not a silent deferral** (above) — logged in
   `packages/core/CHANGELOG.md` under Breaking.
2. **`ProcessReceipt` reassertion is loud, not silent.** §7.1's runtime-replacement check now
   `warn`s naming the offending source when `debug.info` can resolve it (falls back to "unknown
   source"), and fires an analytics event (`ProcessReceiptHijacked`) before reassigning itself, so
   a real conflict is visible instead of an invisible fight over who grants purchases.

## core-v1.3.0 Phase 0 step 4 (module API runtime, `packages/framework/`)

Built standalone (not yet moved into the real layout; that's step 5), 60 new Lune tests, full
suite green (72 spec files, 546 tests). `defineModule`, resolve/loader, config/items/theme
validation, per-module data sections with migrations+sanitize+owner registry, sealed `tx`,
`StudWork.use` restricted to `ModuleRef`s, extensions in both directions (including inverted),
lifecycle, and the `_framework` v1.2-split migration are full implementations, independently
spot-checked (not just taken on the builder's word): confirmed `data.replicate = true` really
errors (M6), `StudWork.use("Data")`/`StudWork.Data` really error naming `ctx.data` (C1), and `tx`
really has no reachable `data` field under `rawget`/`pairs`/iteration (H1). `ctx.net`,
`ctx.replicate`, `ctx.compliance`, `ctx.policy`, `ctx.shop`, `ctx.events` are explicitly-labelled
stubs (`server/Stubs.luau`) for later this phase — `compliance.roll`/`spendForRoll`/`tagPaid` and
`policy.*` raise "not implemented" rather than silently succeeding, so nothing can produce an
undisclosed paid roll through them by accident.

Decisions on the builder's open questions, before Phase 1:
1. **Rojo mapping gains `ReplicatedStorage.Framework`/`ServerScriptService.Framework`** when
   `packages/core` moves to the new layout in step 5, matching module-api.md §1/§2's
   `require(ReplicatedStorage.Framework)`. Confirmed, done as part of step 5.
2. **Finer modules (§17 Q2) each get their own `data.key`, not one combined `economy` key.** The
   v1.2→sections split (`FrameworkSection.V12_MAP`) must target: `currency`/`multipliers` ->
   Economy's own `economy` key, `upgrades` -> Upgrades' own `upgrades` key, `rebirths` ->
   Rebirth's own `rebirth` key, `displayed` -> Plot's `plot` key, `inventory` -> Inventory's
   `inventory` key, `pity` -> Rarity's `rarity` key, `mail.box`/`mail.outbox` -> Mail's `mail`
   key, `streak` -> Streak's `streak` key, `game` -> the game's own implicit module key. No
   handoff migration (M2) is needed for this: it's a one-time split at v1.3's creation, not a
   move between two sections that already independently exist and evolve, which is what M2 was
   deferred for.
3. **`StudWork._attach`/`_installStarter` move off the public `StudWork` table.** An
   underscore-prefixed escape hatch on the same table game/kit code indexes into is exactly the
   kind of back door Phase 2's "nothing is special" lint rule (philosophy §3) is supposed to
   catch; leaving it there now means allowlisting it later, which defeats the rule. Move them to
   a separate internal-only module (`packages/framework/server/Boot.luau`, required only by the
   framework's own server/client `init.luau`, never by `StudWork`) in step 5's reorg. Not
   blocking for Phase 1 since no kit touches it, but must be done before Phase 2's lint check is
   written.
4. **The config schema syntax (enums, ranges, described keys) is approved as specified.** Small
   extension of v1.2's existing format (module-api.md §11); freeze it.
5. **`start(ctx)` does not yield either, same as `init(ctx)`.** Long-running work goes through
   `ctx.lifecycle.onTick`/a `task.spawn`'d loop started from inside `start`, not a yield in
   `start` itself — this matches how every v1.2 service's `start()` already behaves and keeps the
   6-step boot sequence (module-api.md §3) synchronous and fail-closed end to end.

