# Known issues

Open findings from the Phase 2 review (`core-v1.0.0`). Critical/High findings were fixed before the
tag (see `packages/core/CHANGELOG.md`). Each entry: severity, where, failure, suggested fix.

## Medium

### M1. Odds display omits pity and mutation chances
- `Rarity.getOdds` returns base item probabilities only. Rolls also force a minimum tier after
  `pity.threshold - 1` misses and add a mutation with `mutationChance` (Rainbow = x5 income).
- The sandbox client computes odds from config weights instead of the server's `getOdds`.
- Fix: additive `Rarity.getOddsDetail(tableId) -> { items, mutationChance, mutations, pity }`,
  replicate it, render mutation/pity lines in `UI.OddsTable`. Until then games with pity/mutations
  on paid tables should state them in the shop text.

### M2. Replication deep-copies and diffs each player's whole PlayerData on every change
- Every income tick (1 s) causes a full snapshot copy + charm-sync diff per player. Estimated
  3–8 ms per second at 50 players x 100 items, ~1 MB/s garbage. Not profiled.
- Fix: per-section version counters in Data and reuse unchanged sub-tables; stop replicating
  `purchases`, `pity`, `funnel`.

### M3. Mail is at-most-once if a handler fails
- Messages are marked processed before handlers finish; an erroring handler loses the message.
- Fix: run handlers in pcall synchronously, call `processed()` only when all succeed.

### M4. Receipt handler and receipt record are two separate writes
- If a handler yields and the session ends before the record, a retry can grant twice; a handler
  that grants then errors also re-grants on retry.
- Fix: record `purchases[id]` in the same non-yielding `Data.update` as the grant (core wrapper).
  Until then: product handlers must not yield and must not error after granting.

### M5. Plot display requests walk the whole plot several times
- `slotParts` runs `GetDescendants` (including display visuals) on each display/render step.
- Fix: cache the slot map per plot session; check `data.inventory[uid]` before slot lookup.

### M7. Facade exposes `init`/`start`; services write each other's data
- Games can call `Core.Economy.start()` again (double income loop). Rebirth/Inventory write
  `displayed` directly; Rebirth requires `Upgrades/UpgradeMath`.
- Fix: expose frozen API tables with only the `Types` fields; route display changes via Plot.

## Low

- **L1** `Data` waits forever if the ProfileStore store can't be chosen (no timeout/kick).
- **L2** Rebirth with `keepInventory = false` also wipes Robux-bought (`paid:`) items. Decide per
  game; consider keeping `paid:` items by default.
- **L3** Blink's pre-listener queue is unbounded if the game errors before `Core.start`.
- **L4** Friends makes duplicate `IsFriendsWithAsync` calls per pair on join (no in-flight dedupe).
- **L5** `GameConfig.admins` is in ReplicatedStorage, so clients can read admin user ids.
- **L6** `Data.update` keeps half-applied writes when `fn` errors.
- **L7** Sanitize drops invalid inventory entries at load without logging.

## Not verified live (needs a human in Studio)

- Leave -> rejoin with saved data and the offline payout (solo Play can't rejoin the same server;
  use Test > Local Server with 1 client, close the client, start another).
- Gifting between two players; real friend co-play multiplier.
- Phone layout in the Device Emulator (the emulator isn't scriptable over MCP).
- Real DataStore behaviour (place is unpublished, so ProfileStore ran in Mock mode).
- Sound ids in `Sounds.luau` were chosen by name, not listened to.
