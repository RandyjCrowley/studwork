# server/Replication

Ships `Types.ReplicatedState` to the **owning player only**, as charm-sync 0.4.1 patches.

API (called by `server/init.luau` and services via `ctx.setReplicated` / `ctx.setReplicatedAll`):
- `init(ctx)`, `start()`
- `set(player, key, value)` - per-player key: `ratePerSec`, `multiplier`, `paidRandomRestricted`, `plotName`, `odds` (also `activeEvents`). Table values are sanitised (`Snapshot.copy`) once here, not on every rebuild: call `set`/`setAll` again after changing a table. Unknown keys warn and are ignored.
- `setAll(key, value)` - same value for everyone (`activeEvents`). A per-player value for the same key wins.
- `peek(player)` - debug: current snapshot.

## Flow
1. One Charm atom per player, key `tostring(UserId)`. `CharmSync.server.addSignalsToClient(player, {[key] = atom})` - a player is only ever subscribed to its own key, so charm-sync cannot build a payload for them with anyone else's state.
2. `DataChanged` (coalesced per frame by Data), `DataLoaded`, `set`, `setAll` mark the player dirty.
3. Each Heartbeat: dirty players get `atom(Snapshot.build(data, extra, shared, { dataCopy = cache:build(data, versionOf), sanitized = true }))`, then `CharmSync.server.flush()` (auto interval disabled: `CharmSync.config.interval = -1`, global to the place).
4. charm-sync diffs last-synced vs new snapshot -> `{ { type = "patch", data = { [key] = diff } } }`; removed values arrive as the `None` marker `{ __none = "__none" }`. Sent with `ctx.net.events.StateSync.Fire(player, payloads)`.
5. `StateInit` (client says "ready") (re)subscribes -> next flush sends `{ type = "init", data = { [key] = fullState } }`. This is the only time the full state is sent.
6. `PlayerRemoving` -> `CharmSync.server.removeClient(player)`, atom + extra keys dropped.

## Section cache (M2, `SectionCache.luau`)
charm-sync's `patch.diff` treats `old == new` as "unchanged" and walks everything else. v1.0.0 deep-copied the whole PlayerData on every rebuild, so every income tick copied and diffed the whole tree.

Now each player has a `SectionCache`: per top-level PlayerData key it keeps the sanitised copy, the source table reference and `ctx.services.Data.sectionVersion(player, section)` at copy time. A rebuild re-copies a section only when its version moved (or its source table reference changed, e.g. reload); every other section reuses last time's copy by reference, so the diff skips it. The top-level `data` table is new each rebuild. Scalar sections are copied by value.

- Server-only sections `purchases`, `pity`, `funnel`, `mail` are **never replicated** (`SectionCache.SERVER_ONLY`).
- Correctness depends on Data's contract: a committed update that changes a section bumps that section's version. With the Phase 0 single-counter stub every section is re-copied (correct, just no savings). If Data has no `sectionVersion`, a fallback counter forces a full copy.
- Bench (`tools/bench`, 50 players x 100 items, Economy tick): see `REPORT_D` numbers in the v1.1 build report; roughly 25x less time and 20x less allocation per tick with real per-section versions.

## Wire safety (`Snapshot.copy`)
String keys or dense arrays only (sparse/mixed numeric keys -> strings; charm-sync `fixArrays` stays on), NaN/inf -> 0, functions/Instances/userdata dropped, depth cap 16. Blink `unknown` = normal Roblox remote serialisation.

## Tests
`Snapshot.spec.luau` (copy isolation, sanitisation, build defaults/precedence, build opts), `SectionCache.spec.luau` (identity reuse, fresh copies on version/reference change, excluded sections, stub behaviour). Benchmark: `tools/bench [runs]` -> `packages/core/bench/replication.luau`.
