# Known issues

Open findings after `core-v1.2.0`. The v1.1.0 review findings N1–N10 are fixed (N8 and N9 within
the limits listed under Low). The v1.2.0 review (`(internal build report, not public)`) found
0 Critical, 2 High, 7 Medium and 8 Low. Fixed before the tag: R2, R4, R5, R8, R15, most of R9 and
part of R14. R1 is mitigated, not fixed. Each entry gives the severity, where it is, how it fails,
and what to do until it is fixed.

## High (residual)

### R1. ProfileStore keeps at most 1000 queued messages per player and drops the oldest

**Fixed in core-v1.3.0 (Phase 2):** Mail caps undelivered gifts per recipient (100) through the framework
shared store and returns uncollected gifts to the sender after 14 days; the 2400-gift test passes on the
real path (`packages/framework/test/sim/GiftSoakReal.spec.luau`). The text below is the v1.2 record.
- Where: `ProfileStore.luau:181,1683` (`MAX_MESSAGE_QUEUE`).
- What protects it now: Mail takes a message out of that queue as soon as the receiver loads it. It
  is either delivered or held in `PlayerData.mail.box`, which now holds up to 500 messages.
- Still exposed: a receiver who **never logs in**, or who already has 500 held messages, while more
  than 1000 messages pile up. The sender has already given the item up, so the oldest gifts are lost.
- Until fixed: game code must not mail items to users who may never return. Pick recipients from
  recently active players and cap undelivered gifts per recipient per day (Example Gifts).
- Possible fix: a per-recipient counter (MemoryStore or DataStore) that `sendGift` checks, or keep the
  outbox entry until the receiver acknowledges.

## Medium

- **R3. An unsent gift waits for its sender.** If the sender leaves or the server shuts down before
  `saveAsync` and `MessageAsync` finish, the gift stays in the sender's outbox until they rejoin.
  - Fix: flush once more in PlayerRemoving or BindToClose, or let any server flush the outboxes of
    users who left.
- **R6. Dead letters can't be replayed on live servers.** Only the Studio console can replay them
  (`mailreplay`), and live servers keep only the newest 25.
  - Fix: an admin-gated live replay. Consider holding "unknown item" gifts in the mailbox instead of
    throwing.
- **R7. Duplicate detection only covers the last 500 ids.** A resend older than that can grant an
  item again if the receiver no longer owns it. This needs a crash between the send and the outbox
  removal, and the sender returning much later.
  - Fix: time-based dedupe for `core_gift`, or expire old outbox entries.
- **R9 (remaining). The packages/ guardrail is a convention.** It works on branch names and staged
  files, so it misses a `packages/` commit made on its own on a branch not named `game*`, and
  anything already merged.
  - Until fixed: review merges of game branches.
- **FIXED in core-v1.3.0 step 4b-IIb: a session stolen during an autosave now kicks the player.**
  ProfileStore ends such a session without `OnLastSave`; framework Store treats that (and
  "External") as a lost session: Data drops the record at once (no autosave, leave, BindToClose,
  saveAsync / Shop settle or late `tx.after` write from the old server) and the runtime kicks with
  `Server.KICK_SESSION_ENDED`. Proven by `packages/framework/test/sim/StolenSession.spec.luau`
  and the SessionLock "holder alive but MessagingService down" case, which now asserts the kick.
- **A long DataStore outage at join leaves the player waiting.** `Data/init.luau:171` passes `Cancel`,
  so ProfileStore's 120 s load timeout is off. The player waits unloaded, with no kick, until the
  outage ends. Defaults are never written over a profile (tested).

## Low

- **R10 (rest of N8).** Read-only views cover `Core.Data.get/getGame` in Studio only.
  `Core.Inventory.get/list` still return live instances, and `Data.onLoaded` handlers get the live table.
- **R11 (rest of N9).** If the player leaves before the receipt's save is confirmed, only the
  analytics are logged. Game `tx.after` effects, `ProductGranted` and the toast are dropped. Never put
  grant logic in `tx.after`.
  *core-v1.3.0 (framework Shop, step 4b):* settled. On leave, the framework makes one more confirmed
  save and then runs the parked `tx.after` effects even though the buyer is gone; only if that save
  can't be confirmed either are they dropped (warned). `tx.after` effects must not assume the buyer is
  still in the server. See `packages/framework/server/Shop/README.md` (N9). The v1.2 `Core.start` path
  keeps the old behaviour until the boot switch (step 4b-II).
- **R12.** `tools/publish` trusts `deploy.json`: hand-editing `test.published.commit` unlocks `--live`.
- **R13 / rest of R14.** The modules and numbers guardrails miss aliases (`local C = Core`,
  `Core["Mail"]`, `local E = Core.Economy`) and neutral names (`local k = 750`). The facade still
  errors at runtime for a disabled module, and the numbers check is only a heuristic.
- **R16 (fixed in core-v1.3.0, Phase 1 E).** `tools/new-game --modules <subset>` copies the full template loop, so lint fails until the
  game code is trimmed (new-game prints the findings). The five scaffolds were trimmed by hand.
- **R17.** When one handler of a kind returns `false`, the handlers before it have already run, and
  they run again on claim. This is documented: handlers must be safe to run twice.
- Net's pre-start queue cap (`PENDING_CAP = 256`) is shared by all players and events.
- `OddsDetail` has no long-run effective rate that includes pity.
- ProfileStore's `EndSession()` always writes once. On a migration failure the session ends with a
  save of the untouched loaded data (never defaults). Documented in `Data/README.md`.
- The Studio console shows `rbxassetid://203785492 … Asset type does not match`. This id is not
  in core; it is probably a Studio or default asset.

## Not verified live (needs a human in Studio)

`docs/manual-qa.md` covers these: Local Server with 1 and 2 clients, Device Emulator presets,
listening to the sounds, and the real DataStore on a published test place. The automated cover is in
`packages/framework/test/sim/`.
- **R18 (core-v1.3.0, §7.1; was numbered R16 by mistake). On live servers ProcessReceipt replacement can't be detected at
  runtime.** `MarketplaceService.ProcessReceipt` is a write-only callback in the engine, so the
  framework's Heartbeat check (which works with the fake platform in tests) is inert live; see
  `receiptCheck().status`. Enforcement is the `purchases` lint guardrail plus Shop claiming the
  callback as the very last boot step. Workaround: never assign ProcessReceipt anywhere; vendored
  packages that do must be patched.

## core-v1.3.0 (StudWork) open items

From the final review (`(internal build report, not public)`); both Highs and the in-scope
Mediums/Lows were fixed before the tag (`P2F-REPORT.md`).
- **R19 (Medium, final review 5).** Built-in kits still use framework-owned Blink events
  (`RequestUpgrade`, `RequestRoll`, ... in `framework.blink`), hard-coded client action names and the kit
  loader fallbacks (`kitLoadServer`, `ModuleClients`). A third-party module can declare its own actions
  (§9), but per-module `net.blink` files and the §1 one-folder-per-module Rojo mapping are follow-up work.
- **R20 (Medium, final review 7, partly closed).** Compliance marks a transaction paid when a paid
  currency is spent through `spendForRoll`/`spendPaid` or a registered currency spender. A module that
  debits a paid currency straight from its own section, bypassing both, can still roll for free in the
  same tx. Guided, not enforced: documented in `docs/framework/guardrails.md`.
- **R21 (Low).** `_framework.purchases` keeps the last 200 receipts (as v1.2); a lost receipt older than
  that could be granted twice. Moving receipts into their own section is a contract change, left for later.
- **R22 (Low).** `Data.saveNow` doesn't bump the `_framework` section version (replication of `_framework`
  facts can lag one change).
- **R23 (Low, perf).** A module that writes `_framework` every tick costs ~1.6-1.9 ms/tick at 50 players
  (it re-walks the receipts). Rule: per-tick stats live in a module's own section. The real kits do this
  (0.60-0.65 ms/tick vs v1.2 0.64).
- **R24 (Low, cosmetic).** With a wider theme display font, auto-widened action-bar buttons can touch the
  top-centre HUD in a small viewport.
- **R3 (rest).** Unsent gift outboxes are retried on leave and at the sender's next login, not from any
  server (that would need the sender's session).
- **CLAUDE.md** still describes the v1.2 layout and the gift workaround: the update is waiting for the
  user's approval (protected file).
