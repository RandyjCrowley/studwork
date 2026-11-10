# Core changelog

Core's public interface (`packages/core/shared/Types.luau`, `packages/core/shared/net/core.blink`)
only gains things: no renames, no removals; old calls are marked deprecated instead.
Every change is recorded here, newest first.

## core-v1.3.0 (in progress — framework restructure)

Contract frozen at `core-contract-v1.3` (Phase 0). Breaking changes are allowed this round, for
the last time (only scaffolds exist, nothing is published): see `docs/decisions.md` and
`docs/framework/module-api.md` for the full design.

### Breaking (framework restructure)

- **No post-boot item registration.** v1.2's `Items.register` could be called at any time, with
  `Items.onRegistered` re-sending disclosed odds for the new items (N3). v1.3 has no equivalent:
  items exist only through `GameConfig.items`, validated once at boot. Calling anything that
  would register an item after `StudWork.start` errors ("items must be declared in
  GameConfig.items; registering items after start is not supported in core-v1.3.0") rather than
  silently no-op'ing, so no item can ever enter a paid random table before its odds are
  disclosed. Full post-boot registration is left for a later version.

## core-v1.2.0 (2026-11-10)

Finishing the platform: open findings N1, N3, N4, N6, N8, N9, game-agent guardrails, multi-player
tests, publishing readiness. Interface additive only (one behaviour change below).

### Phase 1 (agents A–D, merged A→D) and Phase 2
- A: Mail mailbox (hold on `false`, claim, cap, config tuning, `mailreplay`), outbox
  (`sendInto`, save-before-send, resend with the same key), `Inventory.sendGift` + `core_gift`
  receiver, reserved `core_` kinds via `Mail.facade`; property test (40 seeds × 300 steps) that
  gifted items are never duplicated or lost; Example Gifts scenario.
- B: luck registry, per-player luck-aware odds (`OddsSync`), N3 re-send on `Items.onRegistered`,
  hard rule 11 enforced in `rollInto` (error) and `RequestRoll` (before spending), `Odds.luckLine`
  in `OddsTable`, Monte Carlo 200k rolls at luck 1 / 1.5 / 3 (+ pity), console `luck`.
- C: Lune multi-server simulation (`packages/core/tests/sim/`: real Data + ProfileStore 1.0.3 with
  session locks on a mock DataStore, virtual clock): leave/rejoin, offline payout + cap,
  two-player gifting, co-play, shutdown while saving, session locks, cross-server gifting;
  `tools/test-sim` (+ soak); `docs/manual-qa.md`.
- D: `tools/publish` gate (test before live, clean tree, placeholder ids, secret-safe key,
  end-to-end dry run, stamping), `docs/publishing.md`, `.githooks/pre-commit` via
  `tools/install`, `tools/dev`, `tools/doctor`, `tools/new-game --modules --no-design-doc`,
  `tools/core-status` sync columns. `tools/test` now also runs `tools/**/*.spec.luau`.
- Lead: RequestGift stays in-server only; `UI.Modal` fits the screen (`ModalFit`); sandbox:
  luck-disclosed Chest, `gift` mail kind, mailbox modal, Studio `SandboxConsole`; template synced;
  five games scaffolded (example-collector, example-courier, example-shop, example-garden, example-gifts).
- Review fixes: R2 same-server `RequestGift` uses `sendGift` when Mail is on; R4 tables priced in a
  paid currency count as paid unless `RollOptions.free = true` (added); R5 an all-table luck
  doesn't reach paid rolls on undisclosed tables; R1 `mailboxCap` default 100 → 500 (mitigation);
  R8/R9/R14 guardrail evasions; R15 exact FNV-1a. Open: `docs/known-issues.md`.

### core-contract-v1.2 (Phase 0)

Behaviour change (no game shipped, so changed in place): a Mail handler returning `false` no
longer counts as a failure; the message waits in the player's mailbox (N1).

Added:
- `Mail.pending(player) -> { MailboxEntry }`, `Mail.claim(player, messageId) -> (ok, reason?)`,
  `Types.MailboxEntry`, `Types.MailOutboxEntry`, `MailState.box?` / `.outbox?`,
  `Types.MailConfig` + `GameConfig.mail?` (`maxAttempts`, `backoff`, `mailboxCap`), ctx-only
  `Mail.sendInto(tx, toUserId, kind, payload, key)` (Context.MailInternal). Kinds `core_*` reserved.
- Client: `ReplicatedState.mailbox?`, `Core.Client.onMailbox(fn(count))`,
  `Actions.claimMail(messageId)` (Blink `RequestMailClaim`, rate 2/s burst 5),
  `HudOptions.onMailbox` + the HUD's "Mailbox (N)" badge (Mail module only).
- `Inventory.sendGift(from, toUserId, uid, reason?) -> (ok, reason?)` (needs Mail; Inventory's
  optional dependencies gain Mail).
- `RarityTableConfig.luckDisclosed?`, `OddsDetail.luck?` / `.luckDisclosed?`,
  `Rarity.getOddsDetail(tableId, player?)`, `Rarity.setLuck(player, luck, tableId?)`,
  `Rarity.getLuck(player, tableId?)`; `roll`/`tx.roll` with `luck = nil` use `getLuck`.
  Hard rule: a paid roll with effective luck ~= 1 errors unless the table is `luckDisclosed` and
  the client was sent odds with that luck (N4).
- ctx-only `Items.onRegistered(fn)` (N3), `ctx.sentReplicated(player, key)` (N4).
- `Core.Net.handle(eventName, blinkEvent, { rate, burst }, handler)` (`Types.NetAPI`,
  `Types.RateLimitSpec`): game remotes through core's Net. "Net" joins `Modules.FOUNDATION`.
- `ConfigValidate`: `mail` section, `luckDisclosed` boolean.
- `Core.version` = "1.2.0".

Fixed:
- N6 legacy (id-less) mail ids include a payload hash.
- N8 in Studio, the facade's `Data.get`/`getGame` return frozen copies (`Data/ReadOnlyView`), so an
  in-place write errors instead of silently skipping replication. Facade builder honours
  `service.facade` overrides.
- N9 `Receipt.forgetPlayer` returns the dropped entries; Shop logs `ProductPurchased` for them.

Tooling: `tools/lune/guardrails.luau` (modules / packages / numbers / remotes, with
`--self-test`) wired into `tools/lint`. Sandbox and template moved their two literal grant
numbers to `Config/Tuning.luau`.

## core-v1.1.0 (2026-11-10)

Hardening before the games: review findings M1–M7 and L1–L7, plus the user's decisions 1–4.
After core-v1.1.0 the interface is additive-only again.

### Fixed (Phase 1 agents A–E, merged A→E)
- M1 full odds disclosure: `Rarity.getOddsDetail` (items, mutation odds, item × mutation outcomes,
  pity odds), replicated as `ReplicatedState.odds`, rendered by `UI.OddsTable`; the sandbox shows
  server odds only. Monte Carlo spec (200k seeded rolls, every outcome within 4 SE).
- M2 replication: per-section `Data.sectionVersion` + `Replication/SectionCache` copy only changed
  sections; `purchases`, `pity`, `funnel`, `mail` are no longer replicated. Bench (50 players × 100
  items, `tools/bench`): 12.9 ms → 0.64 ms per tick, 6300 → 400 new tables per tick.
- M3 Mail at-least-once: idempotency keys (`seen`), synchronous pcall'd handlers, retries with
  backoff, dead letters + `MailDeadLetter` analytics, pending until a handler registers.
- M4 receipt-safe purchases: handler + `purchases[id]` in one non-yielding `Data.update`;
  yield/error/`retryLater` commit nothing; `PurchaseGranted` only after the save is confirmed;
  property test (300 random sequences: never a double grant, never a record without its grant).
- M5 Plot: per-session slot cache, ownership check before any slot lookup.
- M7 frozen facade (Phase 0) + no cross-module section writes (Rebirth reset steps).
- L1 bounded store wait + kick; L3 Net listens at require time with a bounded pre-start queue;
  L4 Friends in-flight pair dedupe; L5 `ServerConfig.admins`; L6 transactional `Data.update`;
  L7 dropped-entry counts logged at load.
- Decision 1 migration failure → friendly kick + `DataLoadFailed` analytics, never saves defaults
  over a profile. Decision 2 `keepOnRebirth`. Decision 3 module loader (foundation + enabled
  modules only, erroring proxies, client action gate, module-aware HUD, foundation-only test
  project). Decision 4 `deploy.json` `coreVersion`/`coreCommit`, `tools/core-status`, GAMES.md Core.

### Fixed from the v1.1.0 review (before the tag)
- N5 rolls priced in a paid currency are tagged `paidcur:<table>`: same trade/policy rules as
  `paid:`, but wiped by rebirth (only Robux-bought `paid:` copies are kept).
- N2 a failed PolicyService lookup keeps retrying every 30 s instead of staying unknown.
- N7 a `Core.start` that throws part-way marks core unusable; every call errors with the boot error.
- N10 Mail ignores deliveries for players who already left.
- Playtest: Studio `receipt` simulation tagged fallback items with the wrong product (ids of 0).

Open: `docs/known-issues.md` (N1 mail dead-lettering, N3/N4 odds edge cases, lows).

### core-contract-v1.1 (Phase 0, frozen for Phase 1)

Breaking (pre-games) also includes, after Phase 1: `Core.Client.Actions.*` error before
`Core.start`; a Mail handler returning `false` is a failure (retried); `ReplicatedState.data` lacks
the server-only sections.

Breaking (pre-games) — allowed once, before any game existed:
- `GameConfig.modules: { ModuleName }` is required. Core is a foundation (Data, Net, Shop,
  Analytics, Policy, Events, Console, Replication; client UI kit, Feedback, Input, Hud) plus
  optional modules (`Items`, `Inventory`, `Rarity`, `Economy`, `Upgrades`, `Rebirth`, `Offline`,
  `Streak`, `Friends`, `Mail`, `Plot`). Manifest: `shared/Modules.luau`.
- `BalanceConfig` module sections (`income`, `inventory`, `rarityTables`, `rebirth`, `offline`,
  `streak`, `friends`) are optional in the type; ConfigValidate requires each one only when its
  module is enabled.
- M7: the facade exposes frozen tables with only the `Types` functions; `init`/`start` and private
  helpers are gone from `Core.<Namespace>` and `Core.Client.*`. Calling a server API before
  `Core.start` errors; a second `Core.start` errors (it already asserted).
- M4: `Shop.onProduct(product, handler)` takes a data-only `ProductHandler`
  `(data, receipt, tx: PurchaseTx) -> ()` instead of `(player, receipt) -> boolean`. Decline with
  `tx.retryLater()` or by erroring.
- M3: `Mail.onReceive` handlers get a third `info: MailInfo` argument and may return `false` to
  report failure (they were fire-and-forget).
- `Data.update` (contract): working-copy semantics (L6), nested same-player updates error.
- `ItemDef.keepOnRebirth` defaults to keeping `paid:` copies (Decision 2): rebirth with
  `keepInventory = false` no longer wipes Robux-bought items.

Added:
- `Core.isEnabled(moduleName)`, `Core.start(config, serverConfig?)`, `Types.ServerConfig`
  (`admins`; L5). `GameConfig.admins` is deprecated (still honoured, with a warning).
- `Rarity.getOddsDetail(tableId) -> OddsDetail?` and `ReplicatedState.odds` (M1).
- `Types.PurchaseTx`, `Types.ProductHandler` (M4).
- `Mail.send(userId, kind, payload, key?)` idempotency key, `Types.MailInfo`,
  `PlayerData.mail: MailState` (seen keys, attempts, dead letters; M3).
- `ItemDef.keepOnRebirth: boolean?` (Decision 2).
- Internal (ctx-only, not on the facade): `Context.Tx` + `server/Tx.luau`, `Data.sectionVersion`
  (M2), `Economy.grantInto`, `Inventory.addInto`, `Rarity.rollInto`, `Rebirth.addResetStep`
  (M7: Upgrades and Plot reset their own sections), `ctx.isEnabled/modules/serverConfig`.
- `core.blink`: no new events (odds ride `StateSync`); comments updated.

## core-v1.0.0 (2026-11-10)

Phase 1 real services merged (A Data, C Items, B Economy, D Plot, E Meta, G Client, F UI) and the
Phase 2 review fixes applied.

Added (additive interface changes):
- `Policy.isKnown(player) -> boolean`: lets Robux handlers tell "policy lookup still running"
  (retry) from "known restricted" (grant a non-random fallback).
- `BalanceConfig.paidCurrencies: { string }?`: currencies sold for Robux. Rolls priced in them are
  paid random items (policy check before spending, results tagged `paid:<table>`, untradeable for
  restricted players).
- UI kit: `UI.ScaledRoot` (full-screen root with the responsive UIScale).

Services:
- Data: ProfileStore 1.0.3 sessions, versioned migrations (`Data/migrations/`), reconcile/sanitize,
  per-game table versioning (`game[gameId]._version`), Studio Mock, `saveAsync`, Mail via MessageAsync.
- Economy/Upgrades/Rebirth/Offline: cached per-player rate, one batched write per tick, stacking
  multipliers with expiry and persistence, cost curves, offline cap.
- Items/Rarity/Inventory/Policy: validation, luck, pity, mutations, exact odds, inventory cap with
  upgrades, atomic transfer with paid-random policy, fail-closed PolicyService lookup with retries.
- Plot: any `CorePlot`-tagged model, `SlotId`/`SlotTag` slots, queueing, Trove clean-up, spawn.
- Shop/Streak/Friends/Events/Analytics: idempotent ProcessReceipt with save-before-grant, gamepass
  cache, UTC streak with grace, co-play detection + multiplier, UTC weekday scheduler + admin and
  console triggers, AnalyticsService wrappers.
- Client: charm-sync replication (local player only, patches), feedback (pops, flash, sounds,
  shake, reduced motion), input abstraction; React UI kit + HUD.

Fixed (review High findings):
- `Data.saveAsync` no longer breaks after one failed save (stamped save sequence checked against
  the successful save's payload instead of counting OnSave vs OnAfterSave).
- Coin-priced rolls where Coins are sold for Robux are now treated as paid random items.
- Restricted players' Robux egg purchases get a non-random fallback instead of looping unprocessed.
Also fixed: shutdown/leave no longer kicks with "opened in another server" (only a stolen session
does); HUD/Panel/CurrencyCounter layout runaway (shadow inside list layouts, UIScale on a
full-screen frame).

Known issues: `docs/known-issues.md`.

## 0.1.1 (2026-11-10, before Phase 1 dispatch)

Additive, approved by the core owner after Gate 0:

- `Data.saveAsync(player) -> boolean`: yields until the profile is committed. Needed so
  `Shop` returns `PurchaseGranted` only after the receipt id is saved.
- Server console (`core/server/Console.luau`, `ctx.console.register`): a server-only
  BindableFunction `ServerScriptService.CoreServer.CoreConsole` for the Studio command bar,
  admin tools and MCP playtests (`:Invoke("help")`).

## core-contract-v0 (2026-11-10)

Phase 0 contract, frozen for Phase 1.

- `Types.luau`: ItemDef, ItemInstance, RarityTier/RarityTierDef, Mutation, PlayerData (schema
  version, multi-currency map, inventory by uid, displayed slots, upgrades, rebirths, persisted
  multipliers, streak, lastSeen, firstJoin, purchases, pity, stats, funnel, per-game `game` table),
  GameConfig (items, balance, products, events, palette, admins, data, analytics), all namespace APIs.
- Namespaces: Items, Rarity, Economy, Inventory, Plot, Rebirth, Upgrades, Offline, Streak, Friends,
  Events, Shop, Policy, Data, Mail, Analytics, Signals; client: state, Feedback, Input, Actions, Hud.
- Network: `core.blink` (RemoteScope CORE) with StateInit, RequestDisplay, RequestClearDisplay,
  RequestRebirth, RequestUpgrade, RequestRoll, RequestGift, AdminTriggerEvent, ClientFunnel,
  StateSync, Feedback, EventState.
- Every service is a working in-memory stub; `_sandbox` boots against them.
