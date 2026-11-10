# server/Replication (agent G)

Ships `Types.ReplicatedState` to the **owning player only**, as charm-sync 0.4.1 patches.

API (called by `server/init.luau` and services via `ctx.setReplicated` / `ctx.setReplicatedAll`):
- `init(ctx)`, `start()`
- `set(player, key, value)` - per-player key: `ratePerSec`, `multiplier`, `paidRandomRestricted`, `plotName` (also `activeEvents`). Unknown keys warn and are ignored.
- `setAll(key, value)` - same value for everyone (`activeEvents`). A per-player value for the same key wins.
- `peek(player)` - debug: current snapshot.

## Flow
1. One Charm atom per player, key `tostring(UserId)`. `CharmSync.server.addSignalsToClient(player, {[key] = atom})` - a player is only ever subscribed to its own key, so charm-sync cannot build a payload for them with anyone else's state.
2. `DataChanged` (coalesced per frame by Data), `DataLoaded`, `set`, `setAll` mark the player dirty.
3. Each Heartbeat: dirty players get `atom(Snapshot.build(Data.get(player), extra, shared))`, then `CharmSync.server.flush()` (auto interval disabled: `CharmSync.config.interval = -1`, global to the place).
4. charm-sync diffs last-synced vs new snapshot -> `{ { type = "patch", data = { [key] = diff } } }`; removed values arrive as the `None` marker `{ __none = "__none" }`. Sent with `ctx.net.events.StateSync.Fire(player, payloads)`.
5. `StateInit` (client says "ready") (re)subscribes -> next flush sends `{ type = "init", data = { [key] = fullState } }`. This is the only time the full state is sent.
6. `PlayerRemoving` -> `CharmSync.server.removeClient(player)`, atom + extra keys dropped.

## Why deep copies
Data mutates PlayerData in place; charm-sync's `patch.diff` treats `old == new` as "unchanged". So every rebuild hands charm-sync a fresh deep copy (`Snapshot.copy`); the previous copy is kept untouched as charm-sync's `lastSyncedValue`.

Cost: per dirty player per frame, one copy + one diff walk of the whole PlayerData (~100 items x ~6 fields = roughly 1-2k values) -> tens of microseconds. Typical dirtiness is the income tick (1/s) per player, so 50 players ~ 50 copies/s - negligible. Worst case (every player dirty every frame) is ~50 x 2 walks per frame; if profiling ever shows it, add structural sharing (reuse unchanged subtrees, e.g. per-uid inventory entries keyed on a version) inside `Snapshot`. The diff itself only puts *changed* leaves on the wire.

## Wire safety (`Snapshot.copy`)
String keys or dense arrays only (sparse/mixed numeric keys -> strings; charm-sync `fixArrays` stays on), NaN/inf -> 0, functions/Instances/userdata dropped, depth cap 16. Blink `unknown` = normal Roblox remote serialisation.

## Tests
`Snapshot.spec.luau` (copy isolation, sanitisation, build defaults/precedence).
