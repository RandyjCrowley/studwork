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

