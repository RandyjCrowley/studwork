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
   pruned to `Schema.PURCHASES_CAP` (200, oldest first).
- Data from NEWER code (or a failing migration): nothing is modified, the session is ended
  (ProfileStore writes back the exact loaded data) and the player is kicked with a rejoin message.

Then `stats.sessions += 1`, `DataLoaded` + `onLoaded` handlers fire (lastSeen still the previous
session's value).

## Saves
- `profile.OnSave` (fires right before every write: autosave, `saveAsync`, leave, shutdown) sets
  `lastSeen = os.time()` and re-prunes purchases. ProfileStore's BindToClose ends every session
  and waits for the writes; Data's BindToClose only stamps lastSeen early.
- `saveAsync`: `profile:Save()` then waits until `OnAfterSave` has fired for that save (30 s
  timeout). False when not loaded, session ended, or timeout.
- `update(fn)`: fn runs in a coroutine; yielding raises an error. DataChanged is coalesced
  per player per Heartbeat.

## Adding a schema migration
Add `migrations/00N_what.luau` returning `{ version = N, migrate = function(old) ... return new end }`,
list it in `Schema.luau` `MIGRATION_MODULES`, bump `CURRENT_VERSION`, add a spec case. Never edit
a shipped migration.

## Studio console
`data dump [userId]`, `data reset [userId]` (fresh defaults, fires DataLoaded),
`lastseen <secondsAgo> [userId]` (kept through saves until leave; rejoin to test Offline).
