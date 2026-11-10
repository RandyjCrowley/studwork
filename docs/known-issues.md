# Known issues

Open findings after `core-v1.1.0`. All v1.0.0 review findings (H1–H3, M1–M7, L1–L7) are fixed; the
v1.1.0 review (`(internal build report, not public)`) found 0 Critical, 0 High, 5 Medium,
5 Low. Fixed before the tag: N2, N5, N7, N10. Each entry: severity, where, failure, suggested fix.

## Medium

### N1. Mail dead-letters a message after ~30 s of handler failures
- `Mail/Delivery.luau` `MAX_ATTEMPTS = 5`, backoff 2+4+8+16 s; `processed()` after dead-lettering,
  and nothing reads or replays `PlayerData.mail.dead` (cap 25).
- A gift handler that returns `false` because the inventory is full loses the gift ~30 s later.
- Fix: treat `false` as "not ready" (stay pending, no attempt counted, retry on DataChanged / next
  session); count only thrown errors; spread attempts across sessions; add a replay path for
  `mail.dead`. **Fix before Example Gifts ships.** Until then: mail handlers should not return
  `false` for transient conditions; store the gift in the game table and grant it later instead.

### N3. Odds are replicated once at Rarity.start
- Items registered after `Core.start` and listed in a paid/costed table are rolled but missing from
  `ReplicatedState.odds` (and `validateTables` only warns about unknown items).
- Fix: re-replicate odds after every `Items.register`, or make unknown items in paid/costed tables
  a config error. Until then: register every item before `Core.start` (put them in `Config.items`).

### N4. Luck is not reflected in the disclosed odds
- `PurchaseTx.roll(tableId, luck)` / `Rarity.roll(..., luck, { paid = true })` roll with luck while
  `state.odds` shows luck-free odds.
- Fix: refuse luck on paid rolls, or add a per-player luck-aware disclosure
  (`getOddsDetail(tableId, luck)` + `setReplicated(player, "odds", ...)`). Until then: **never pass
  luck to a paid roll.**

## Low

- **N6** Legacy (v1.0, id-less) mail messages of the same kind sent in the same second share an id;
  the second is consumed without running. No game shipped on v1.0, so none should exist.
- **N8** In-place writes through `Data.get`/`getGame` (against the rules) are saved but no longer
  replicated (the section cache only re-copies sections whose version/reference moved). Consider a
  read-only view in Studio.
- **N9** If a receipt's save fails and the player leaves before the retry, the grant persists but its
  post-grant effects (signals, toast, `ProductPurchased` analytics) are dropped.
- Net's pre-start queue cap (`PENDING_CAP = 256`) is shared by all players and events.
- `OddsDetail` has no long-run effective rate including pity (optional interface request from B).
- Mail limits (5 attempts, 500 remembered ids, 25 dead letters) are untuned.
- ProfileStore's `EndSession()` always writes once: on a migration failure the session ends with a
  save of the untouched loaded data (never defaults). Documented in `Data/README.md`.

## Not verified live (needs a human in Studio)

- Leave → rejoin with saved data and the offline payout (solo Play can't rejoin the same server;
  use Test > Local Server with 1 client, close the client, start another).
- Gifting between two players; real friend co-play multiplier.
- Phone layout in the Device Emulator (not scriptable over MCP). Re-check the odds modal now that
  the sandbox action screen draws above the HUD.
- Real DataStore behaviour (place is unpublished, ProfileStore runs in Mock mode), including
  receipts across a real server crash and mail across servers.
- Sound ids in `Sounds.luau` were chosen by name, not listened to.
