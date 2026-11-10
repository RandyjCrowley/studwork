# Core.Data

ProfileStore 1.0.3 player data. Public API: `Types.DataAPI` (`get`, `update`, `onLoaded`,
`isLoaded`, `getGame`, `updateGame`, `saveAsync`).

## Store
- Name `PlayerData_<gameId>` (`PlayerData_<gameId>_Studio` in Studio with API access), key
  `Player_<userId>`, `profile:AddUserId(userId)` so GDPR erasure templates match.
- Studio without DataStore access: waits for ProfileStore's own access probe
  (`ProfileStore.DataStoreState`), then uses `store.Mock` and warns once. Mock data lives only in
  that server's memory (rejoin inside the same Studio run keeps it).
- Session locking is ProfileStore's: `StartSessionAsync` with a `Cancel` that stops when the
  player leaves mid-load. Load failure or a session taken by another server -> friendly kick.
- Choosing the store is pcall'd (L1); `loadPlayer` waits at most `STORE_WAIT_TIMEOUT` (30 s,
  `Load.awaitStore`), then kicks with the load-failed message.

## Load pipeline (`Schema.prepare`, pure)
1. Empty profile -> `Schema.default` (startingCurrency, `lastSeen = firstJoin = now`).
2. Else deep copy, `Migrate.run` from `schemaVersion` (missing = 0) to `Schema.CURRENT_VERSION`
   with `Schema.MIGRATIONS` (`migrations/NNN_*.luau`, each `{ version, migrate }`).
3. Reconcile missing keys / wrong types from defaults (new currency ids start at 0 for
   existing players).
4. Game table `game[gameId]`: version stored in reserved key `_version` (missing = 1),
   `config.data.migrations[toVersion]` run up to `config.data.version`, reconciled with
   `config.data.defaults`.
5. `Sanitize.playerData` (finite numbers, valid items/multipliers/displayed) and purchases
   pruned to `Schema.PURCHASES_CAP` (200, oldest first). It returns a report
   `{ inventory, other }`; Data warns with the userId and counts when non-zero (L7).
- The decision is `Load.decide` (pure). It never replaces or mutates `profile.Data` on failure.
- Data from NEWER code: nothing is modified, the session is ended and the player is kicked with
  the "older version" message.
- Failing migration / unreadable data (Decision 1): `DataLoadFailed` analytics (pcall, spawned),
  session ended, kick with `We couldn't load your save safely. Please rejoin. Your progress is safe.`
  ProfileStore 1.0.3's `EndSession` always performs one release save, but it writes back the exact
  loaded data (no OnSave hook is connected yet), never defaults.

Then `stats.sessions += 1`, `DataLoaded` + `onLoaded` handlers fire (lastSeen still the previous
session's value).

## Saves
- `profile.OnSave` (fires right before every write: autosave, `saveAsync`, leave, shutdown) sets
  `lastSeen = os.time()` and re-prunes purchases. ProfileStore's BindToClose ends every session
  and waits for the writes; Data's BindToClose only stamps lastSeen early.
- `saveAsync`: `profile:Save()` then waits until `OnAfterSave` has fired for that save (30 s
  timeout). False when not loaded, session ended, or timeout.
- `update(fn)` (L6, `Transaction.luau`): fn gets a proxy. The first read of a table section
  deep-copies only that section; scalar writes are recorded; `for k, v in data` works (copies
  every table section it visits), `next`/`rawget`/`table.clone(data)` do NOT. Commit only when fn
  returns: an error discards everything and re-raises with a traceback (table errors as-is),
  a yield discards and errors, a same-player update inside a running one errors
  `nested Data.update`. Committed sections are written back into the same root table; sections
  deep-equal to the original keep their table identity. `Data.get` inside fn returns committed data.
- `sectionVersion(player, section)` (ctx-only): globally increasing per section; moves on a
  committed change, on Data's own writes (lastSeen on save/leave/console, the `stats._saveSeq`
  stamp in saveAsync, purchases pruning) and for every section on console `data reset`.
- DataChanged is coalesced per player per Heartbeat (only when an update changed something).

## Adding a schema migration
Add `migrations/00N_what.luau` returning `{ version = N, migrate = function(old) ... return new end }`,
list it in `Schema.luau` `MIGRATION_MODULES`, bump `CURRENT_VERSION`, add a spec case. Never edit
a shipped migration.

## Studio console
`data dump [userId]`, `data reset [userId]` (fresh defaults in the same root table, bumps every section, fires DataLoaded),
`lastseen <secondsAgo> [userId]` (kept through saves until leave; rejoin to test Offline).
