# Adopting StudWork in an existing game (design, v1.6.0)

Status: **frozen** (v1.6.0; the design review's Critical and High findings are folded in, see
[decisions.md](../decisions.md), "v1.6.0 adoption"). This page is the source of truth for adoption:
the `tools/adopt` commands, the legacy data import, the purchase bridge, the transitional
guardrails, and the two Rarity additions shipped in the same release. The API parts are also listed
in [module-api.md §20](module-api.md). The step-by-step playbook for a coding agent is
[docs/agents/adopt-existing-game.md](../agents/adopt-existing-game.md).

The goal: point any coding agent at a StudWork checkout and an existing Roblox game, say "migrate
it", and have it finish quickly without help, with no way to lose a player's save or a Robux
purchase along the way.

**Three rules hold everywhere on this page:**

1. **StudWork never writes the old store.** No framework path calls `SetAsync`, `UpdateAsync`,
   `RemoveAsync`, `IncrementAsync` or any other write on a legacy store: the legacy reader gets a
   read-only wrapper with read methods only. (Old game code that still runs can write; that's what
   the transitional guardrails, `tools/adopt --verify` and the publish gate stop before going
   live, §5.)
2. **The tools never touch live data.** `tools/adopt` and `tools/test-migration` read code, place
   files and sample-save fixtures only. They never call Open Cloud, never read or write a real
   game's DataStores, and never publish. Reading old saves happens only inside the running game,
   at join, through the framework (§3).
3. **A failure changes no data.** Every new path fails closed: a failed import kicks the player
   with a friendly message and changes neither store's data (ProfileStore may still write its
   session metadata when the session ends); a failed receipt check answers `NotProcessedYet`, so
   Roblox retries.

---

## 1. The audit: `tools/adopt --audit <project> [<project> ...]`

`<project>` is a Rojo repo (a folder with a `*.project.json`) or a bare place file
(`.rbxl` / `.rbxlx`, read with Lune's `@lune/roblox`). Several projects can be given: the places of
one universe (a lobby and a game share DataStores), and the report then lists every store each of
them uses (`sharedStores`). The audit only reads. It writes two files into the (first) project's
root, or next to the place file:

- `studwork-adopt-report.json`: the machine-readable report (schema below).
- `studwork-adopt-report.md`: the same, for a person, ending with the numbered migration plan.

Both are regenerated on every run (stable order, so a diff shows what changed). Nothing else is
written. Exit code 0 on success, 1 if a project can't be read.

### What it detects

The audit scans every script's source: in a Rojo repo every `.luau`/`.lua` the project file maps
(`*.server.luau`, `*.client.luau`, plain modules, `init.*`), and in a place file every
`Script`/`LocalScript`/`ModuleScript` with its full instance path and `RunContext`.

| Area | What it finds | Report key |
|---|---|---|
| Scripts | path, class (Script / LocalScript / ModuleScript), side (server / client / shared, from class, `RunContext` and container), line count | `scripts` |
| DataStores | every `GetDataStore` / `GetOrderedDataStore` / `GetGlobalDataStore` call: store name (literal or `"<dynamic>"`), scope, and every read/write call on the result (`GetAsync`, `SetAsync`, `UpdateAsync`, `IncrementAsync`, `RemoveAsync`, `GetSortedAsync`, `ListKeysAsync`) with file:line and the key expression, turned into a key pattern when it's derivable (`"Player_" .. player.UserId` -> `Player_{userId}`) | `datastores` |
| Save libraries | ProfileService (`GetProfileStore`, `LoadProfileAsync`), ProfileStore (`ProfileStore.New`, `StartSessionAsync`), DataStore2 (`DataStore2(`, `DataStore2.Combine`, `:Get`/`:Set`/`:Increment`), each with the store name, scope, key pattern and combined keys when literal | `libraries` |
| Purchases | `ProcessReceipt` assignments (and whether the handler checks a purchase history before granting), `PromptProductPurchase` / `PromptGamePassPurchase` / `PromptPurchase` calls, `Prompt*PurchaseFinished` connections, `UserOwnsGamePassAsync` / `PlayerOwnsAsset` checks, every numeric product / pass id literal near them; and, per product handler, the save fields it grants (`sold`: a currency or item field written in the handler), and whether the handler uses randomness | `purchases` |
| Remotes | `RemoteEvent` / `RemoteFunction` / `UnreliableRemoteEvent` / `BindableEvent` instances (in the place, in the project's `.model.json`/`.rbxmx`, or created by `Instance.new`) with their path, and every handler (`OnServerEvent`, `OnServerInvoke`, `OnClientEvent`, `OnClientInvoke`) and firing call with file:line | `remotes` |
| leaderstats | code creating a `leaderstats` folder and the value objects under it (name, class) | `leaderstats` |
| UI | everything under `StarterGui` (place) or mapped to it (Rojo): ScreenGuis with their child count and the scripts inside them | `ui` |
| Globals | `_G.` / `shared.` reads and writes, `require(<number>)` (asset requires), `loadstring` | `globals` |

Detection is static and heuristic. Anything it can't resolve (a store name built at runtime, a key
it can't turn into a pattern) is reported as `"<dynamic>"` with the file:line, never guessed. A
Rojo `$path` outside the project root (`../shared`) is reported as `external:<path>`; the audit
never writes next to it.

### Risk levels

Every finding that matters for a safe migration becomes a `risks[]` entry:

| Level | Meaning | Examples |
|---|---|---|
| `critical` | Doing this part wrong loses saves or Robux. The plan handles it first. | a `ProcessReceipt` that grants without a purchase-history check; two scripts writing the same store/key (duplicated save logic); a player-save key that isn't derivable from the userId (the import can't find it); `RemoveAsync` on player data; a store another place of the universe also writes; a product handler that uses randomness; a store named `PlayerData_<x>` with key `Player_{userId}` (it would collide with StudWork's own store) |
| `high` | A security or compliance problem the migration must fix. | a remote handler that takes an amount, price, item id or position from the client and writes it; a paid random item (a product or paid currency next to `math.random` / `Random.new`) with no odds shown; `SetAsync` on a player save without a session lock; a script left in the place (`notExtracted`) that uses DataStores or purchases |
| `medium` | Works, but StudWork does it differently; the agent decides. | `_G`/`shared` state; leaderstats as the source of truth; `wait()` loops; asset `require`s |
| `low` | Notes. | unused remotes, empty scripts, very large scripts |

### Report schema (`studwork-adopt-report.json`, `reportVersion = 1`)

```jsonc
{
  "reportVersion": 1,
  "tool": "studwork-adopt",
  "studwork": "1.6.0",
  "projects":   [ { "kind": "rojo" | "place", "root": ".", "projectFile": "default.project.json", "placeFile": null } ],
  "scripts":    [ { "path", "class", "side", "lines", "project" } ],
  "notExtracted": [ { "path", "class", "findings": [ ] } ],
  "datastores": [ { "name", "scope", "kind": "global" | "ordered", "keyPatterns": [ ], "calls": [ { "op", "file", "line", "key" } ] } ],
  "libraries":  [ { "name": "ProfileService" | "ProfileStore" | "DataStore2", "store", "scope", "keyPattern", "combined": [ ], "file", "line" } ],
  "sharedStores": [ { "name", "projects": [ ] } ],
  "purchases":  { "processReceipt": [ { "file", "line", "historyCheck": true } ],
                  "products": [ { "id", "file", "line", "sold": [ "gems" ], "random": false } ],
                  "passes": [ { "id", "file", "line" } ], "prompts": [ ], "ownership": [ ] },
  "remotes":    [ { "name", "class", "path", "handlers": [ { "kind", "file", "line" } ], "fires": [ ] } ],
  "leaderstats":[ { "file", "line", "values": [ { "name", "class" } ] } ],
  "ui":         [ { "path", "class", "scripts": [ ] } ],
  "globals":    [ { "kind", "file", "line" } ],
  "risks":      [ { "id", "level", "message", "file", "line" } ],
  "plan":       [ { "n", "id", "title", "auto": false, "files": [ ], "do": "…", "check": "…" } ]
}
```

Paths in the report are relative to the project root (never absolute).

### The plan

`plan[]` is a numbered list an agent follows top to bottom; each step names its files, what to do
and how to check it. The order is fixed; steps with nothing to do are left out:

1. **init** (`tools/adopt --init`, automatic).
2. **save map**: write the mapping from every old save field to its new home (a kit section
   through the kit's `txApi`, or the game module's own section). One table in the game module's
   README. A field a product sells (`purchases.products[].sold`) maps to a currency listed in
   `compliance.paidCurrencies` (or to an item, which the import tags paid).
3. **legacy import**: `ctx.data.importLegacy` (§3) with synthetic sample-save fixtures per old
   store, and `tools/test-migration` green.
4. **purchases**: every product to `ctx.shop.onProduct`; the legacy receipt history (§4); passes
   to `ctx.shop.onPassOwned` / `ownsPass`.
5. **remotes**: every remote to a module action (one entry per remote, with its handler and what
   the server must validate).
6. **leaderstats**, then **UI** (keep the old UI, or move screens to the UI kit), then each
   remaining system.
7. **shrink the legacy list**: delete or port each file in `studwork-legacy.json` until it's empty
   or every entry is justified.
8. **verify**: `tools/adopt --verify`, `tools/lint`, `tools/typecheck`, `tools/test`,
   `tools/test-migration`, `tools/build`.
9. **cutover checklist** for the user (§2). The agent stops here.

### `tools/adopt --verify <project>`

Re-runs the audit and fails (exit 1) while any `critical` risk remains, while a `notExtracted`
script (left in the place file) uses DataStores, `ProcessReceipt` or product prompts, while any
`onLegacyProduct` call is left (§4.3), or while `studwork-legacy.json` has an entry listing the
`purchases` check. It prints what's left, one line each. It's the last automatic step of the plan.

### `tools/adopt --from-place <file> [--out <dir>]`

For a Studio-only game. It reads the place and writes a Rojo project for the **code containers
only**, so the map, models and UI stay in the place:

- Containers: `ServerScriptService`, `ServerStorage`, `ReplicatedStorage`, `ReplicatedFirst`,
  `StarterPlayer.StarterPlayerScripts`, `StarterPlayer.StarterCharacterScripts`.
- Every script becomes a file (`.server.luau`, `.client.luau`, `.luau`; a script with children is
  a folder with `init.*`), folders between them become folders. Each mapped container gets
  `"$ignoreUnknownInstances": true`, so instances that stay in the place (models, remotes, values)
  are kept when Rojo syncs.
- **Names are untrusted input.** An instance name becomes a file name only after sanitizing:
  path separators, `.` / `..`, control characters, characters invalid on Windows or macOS and
  reserved names (`CON`, `NUL`, ...) are escaped, and the real name is kept in a `.meta.json`
  (`"properties": { "Name": "…" }`). Collisions are detected case-insensitively (macOS) and get a
  `~2` suffix; every one is reported.
- **Every write is contained:** each target is checked to be inside `--out` after resolving
  symlinks, or the run stops before writing anything.
- **No silent overwrite:** the run writes `.studwork-from-place.json`, a manifest of every file it
  generated with its content hash. A later run overwrites a file only if it's in the manifest with
  an unchanged hash; any other existing file stops the run. A fresh `--out` must be empty or not
  exist.
- Scripts inside `Workspace`, `StarterGui`, tools and models are **not** moved (their parent is
  part of the map or UI); the report lists them under `notExtracted` with their findings, and
  `--verify` refuses to pass while one of them still uses DataStores or purchases.
- `RunContext` and `Disabled` are kept as `.meta.json` properties.
- `--out` defaults to the folder of the place file. The place file itself is never modified.
- A place-file game is published from Studio (open the place, sync with `tools/dev`, publish), not
  with `tools/publish` (its build has no map); `tools/publish` says so and stops for a project whose
  `studwork.json` has `"placeFile"`.

## 2. The adoption flow

```
audit ──> init ──> migrate system by system ──> verify ──> cutover (the user)
```

| Step | Automatic (tools) | The agent decides |
|---|---|---|
| **audit** | `tools/adopt --audit` writes the report and the plan | nothing yet; it reads the plan |
| **init** | `tools/adopt --init` adds the `studwork/` submodule, `studwork.json`, the tool wrappers, a game module, the merged project file and `studwork-legacy.json` (§5) | the game id, the module list (`--modules`) |
| **migrate** | `tools/make-module`, `tools/make-migration`, `tools/test-migration` | the save map, which kit owns what, each remote's validation, what to keep from the old UI. Independent systems (remotes of different features, UI screens) can be done by parallel agents, each owning its files |
| **verify** | `tools/adopt --verify`, `tools/lint`, `tools/typecheck`, `tools/test`, `tools/test-migration`, `tools/build` | each remaining legacy entry's reason |
| **cutover** | nothing (no tool publishes live for the agent) | nothing: **the user does it** with the checklist |

### `tools/adopt --init <project> [--name <gameId>] [--modules A,B] [--tag vX.Y.Z] [--url <u>] [--dry-run]`

- Requires a git repo at `<project>` with a clean tree for the paths it writes (it refuses
  otherwise), and either a `*.project.json` or a `--from-place` output.
- Adds the `studwork/` submodule pinned to a release tag (default `v<StudWork.VERSION>`), exactly
  like `tools/new-project` (no network if `--url` is a local path).
- Writes `studwork.json` = `{ "layout": "single-game", "framework": "studwork", "adopted": true,
  "placeFile": "<file>"?, "legacyBaseline": { "files": { "<path>": { "<check>": <findings> } } } }`.
- **Refuses a game id that collides with an old store:** StudWork saves to `PlayerData_<gameId>`
  (`_Studio` in Studio) under `Player_{userId}`; if the audit found an old store of that name, init
  stops and asks for another `--name`. (The framework also refuses it at boot, §3.)
- Copies the single-game tool wrappers into `tools/` (an existing `tools/<name>` that isn't a
  StudWork wrapper is left alone and reported).
- Creates the game module `modules/<gameId>/` (`module.luau`, `server/init.luau`) with the
  `importLegacy` and bridge calls stubbed and commented, and `src/shared/Config/` if missing.
- **Merges** the existing `default.project.json` instead of replacing it: it adds the framework,
  UI, Packages and `Modules` entries and the game module; existing entries are kept as they are.
  If an existing entry occupies a name StudWork needs (`ReplicatedStorage.Framework`, `.Modules`,
  `.Packages`, `.UI`, `.GameModule`, `ServerScriptService.Framework`, `.Modules`), it stops and
  reports the clash instead of overwriting it.
- Fills `studwork-legacy.json` (§5) with every file that has a finding of a guarded check (it runs
  the same guardrails `tools/lint` runs, ignoring any legacy list: `guardrails --raw`), each entry
  with a reason taken from the audit when one applies.
- **Repeatable**: a second run changes nothing (byte-identical output) unless the inputs changed;
  it never raises or rewrites `legacyBaseline` once committed.
- `--dry-run` prints every file it would create or change (with a diff for merged files) and
  writes nothing.
- It never writes outside `<project>` (every target path is checked to be inside it, after
  resolving symlinks).

### Cutover (the user's checklist; the agent never does it)

1. **Every place of the universe** that reads or writes an imported store is migrated too, or has
   its old save code removed (the audit's `sharedStores`). A lobby still on old code would keep
   writing the old store after its players were imported.
2. Publish the migrated place to a **test place in the same universe** (it shares DataStores with
   live, so it can read real old saves). Every account that joins it is imported for real: use
   test accounts that played the old game. `tools/publish --test`, or Studio for a place-file game.
3. In the test place, join with such an account and compare: the save matches the old one field by
   field (the console's `data dump <userId>` and `adopt status <userId>`).
4. Buy one product in the test place and confirm one grant.
5. Publish live with **"Shut down all servers"** (not a migrate-to-latest update, which keeps old
   servers running while they have players), so no old server writes the old store after its
   players are imported. The import also refuses to read a save written in the last
   `Legacy.QUIET_SECONDS` (120 s, §3), which covers the old servers' final saves.
6. `tools/publish --live` refuses while `tools/adopt --verify` would fail (§1, §5).
7. Watch the logs and analytics for `LegacyImportFailed`, `LegacyChangedAfterImport` and the
   share of `LegacyNotFound` for a few days.

**Rollback** is possible, and it is lossy only in a way the next cutover repairs: the old store is
never changed by StudWork, so publishing the previous place version (Roblox version history)
brings the old game back with every save as it was when each player was imported. Progress made
on StudWork stays in the StudWork store. Progress (and purchases) made in the old game during the
rollback are written to the old store after the import time, so when StudWork is published again
the import sees **changed after import** (§3) and runs the module's `merge`; a module without
`merge` fails closed for those players (kick, nothing written, `LegacyChangedAfterImport`) until a
merge ships. Nothing is silently dropped either way.

## 3. The legacy data import (`ctx.data.importLegacy`, added in v1.6.0)

A module declares, in its server `init`, a one-time import of a player's old save:

```lua
ctx.data.importLegacy({
	id = "v1-save",                       -- stable id of this import (the marker key); never reuse it
	version = 1,
	source = { kind = "datastore", name = "PlayerData", key = "Player_{userId}" },
	-- or a map of named sources: source = { main = {…}, stats = {…} } -> `old` is { main = …, stats = … }
	import = function(tx, old, info)      -- first import: non-yielding; same rules as ctx.tx
		ctx.depsTx[Economy].grant(tx, old.coins or 0, "legacy_import")
		for _, id in old.inventory or {} do
			ctx.depsTx[Inventory].add(tx, id, { source = "legacy_import" })
		end
		ctx.section(tx).settings = old.settings
	end,
	merge = function(tx, old, info)       -- optional: a re-run for a player who already has a marker
		-- info.previous = the marker; info.reason = "changed" | "version"
	end,
	receipts = function(old) return old.purchases end,  -- optional: old PurchaseIds (§4.1)
	itemTag = "paid",                    -- optional, default "paid" (below)
})
```

### Registration

- Any module may register, **once**, in `init` (after `init`, or a second time, it errors). Usually
  the game module, which declares the kits it fills in `dependsOn` and writes them only through
  their `txApi` (nothing reaches another module's section; hard rule 7 holds).
- `id` is required: a short id string, unique across the game, and stable for the life of the game
  (renaming a module doesn't re-import anyone; the marker is keyed by `id`).
- **Boot error on a store collision:** a source whose store name equals StudWork's own save store
  (`PlayerData_<gameId>`, also with `_Studio`) is refused, whatever the key.

### Sources (`kind`), read only through the framework's read-only reader

- `"datastore"`: `GetDataStore(name, scope?)`, key pattern with `{userId}`; the value as stored.
- `"profileservice"` / `"profilestore"`: the same store, scope and key the library used
  (`GetProfileStore(name)` / `ProfileStore.New(name)`, key e.g. `Player_{userId}`); `old` is the
  profile's `Data`. A session lock held by a live old server (`MetaData.ActiveSession` set and
  the profile updated within `Legacy.SESSION_STALE_SECONDS` = 1800 s) is a **busy** read.
- `"datastore2"`: DataStore2's default ordered-backups format: the OrderedDataStore
  `<name>/<userId>` gives the latest version, the DataStore `<name>/<userId>` holds the value
  under that version's key. With `combined = { "coins", "inventory" }` (DataStore2's `Combine`
  master key as `name`), `old` is the table of those keys. `savingMethod = "Standard"` reads the
  plain-DataStore form instead. (The exact layout is checked against DataStore2's source and
  recorded in `Legacy.luau`.)
- Keys use only `{userId}`; a source whose key needs anything else isn't importable at join
  (the audit flags it as critical).
- Every read passes `DataStoreGetOptions.UseCache = false` (no stale cached value).
- **Quiet window (every kind):** a value whose last update (`DataStoreKeyInfo.UpdatedTime`,
  milliseconds, converted to seconds) is within `Legacy.QUIET_SECONDS` = 120 s of now is a **busy**
  read: an old server may still be writing its final save.
- A busy read, like a failed one, fails the load (below); the next join tries again.

### When it runs, and the marker

- Every join while an import is registered, inside the framework's load: after the StudWork save
  is loaded and migrated, **before the player counts as loaded** (no `onLoaded`, no actions, no
  purchases see the player before the import committed: receipts get `not_loaded` meanwhile).
- **Reads first** (they yield; up to 3 attempts with backoff for errors and throttling), then a
  re-check that the StudWork session is still held and the player is still in the server (a
  session taken by another server during the reads discards everything), then **one non-yielding
  transaction** that runs `import` or `merge` and writes the marker. The transaction is run by
  Data directly on the not-yet-published record (`runImportTx`), not through `ctx.tx`.
- **The marker:** `_framework.imports[id] = { v = version, at = <unix>, found = bool,
  sources = { [name] = { found, updatedAt? } } }`, written by the framework in the **same commit**
  as the imported data. `_framework.schemaVersion` doesn't change (the field is additive), so a
  v1.5 framework still loads the save.
- What runs, per join:

  | Marker | Old save now | Runs |
  |---|---|---|
  | none | none found | nothing; marker `found = false` |
  | none | found | `import` |
  | `found = false` | none found | nothing (re-checked every join, so a misconfigured source can be fixed) |
  | `found = false` | found | `import` (nothing was imported before, so nothing doubles) |
  | `found = true`, same `version`, no source updated after `at` | any | nothing |
  | `found = true`, a source updated after `at` (+5 s skew) | found | `merge` with `info.reason = "changed"` |
  | `found = true`, marker `v` < `version` | found | `merge` with `info.reason = "version"` |

- **No `merge`, but one is needed:** the load fails closed (kick, nothing written) and analytics
  `LegacyChangedAfterImport` fires. A game that never rolls back and never bumps `version` never
  needs one.
- `info = { userId, found, reason, previous (marker or nil), sources = { [name] = { found,
  updatedAt? } }, now }`.
- `merge` must be idempotent: run twice with the same `old`, the save is the same.
  `tools/test-migration` checks it (below). `receipts(old)` runs again on every `import` and
  `merge`.

### Failure never changes data

Any of these fails the whole load: a read error after the retries, a busy read, a value of the
wrong type (a non-table where the reader expects one), `import`/`merge` erroring or yielding, a
lost session. The player is kicked with *"We couldn't bring over your save from the previous
version yet. Nothing was lost. Please rejoin in a minute."*; the StudWork session ends without a
data change (the same path as a failed migration, `store.reject`); the old store was only read. The
next join tries again. Every failure is logged and sent as analytics `LegacyImportFailed` with the
reason (`read_error`, `busy`, `import_error`, `lost_session`, `merge_missing`; no data), so a
deterministic import error shows up as a repeated reason for one player instead of a silent loop.

### Kit limits fail closed in an import

An import must never write the marker after dropping something. Inside an import transaction:

- **A refused txApi call raises.** The framework wraps every `ctx.depsTx[...]` function while an
  import transaction runs: a first return value of `nil` or `false` raises
  `legacy import: <Module>.<fn> refused (<value>)`, so the import fails closed instead of
  committing a partial save.
- **Caps don't apply to imported data:** `ctx.data.isImport(tx) -> boolean` (added) lets a kit tell
  an import transaction apart. Inventory skips its cap check in an import (an old player with more
  items than the cap keeps all of them; they just can't add more until under the cap), so a legit
  old save never fails on a cap.
- **No randomness:** `ctx.compliance.roll` / `spendForRoll` / `spendPaid` inside an import
  transaction error. An import copies; it never rolls.
- **Items are tagged as paid** (`itemTag = "paid"`, the default): a copy added in the import
  transaction gets the source `paid:legacy` (Compliance's `tagPaid(tx)` derives it from the
  framework-set import flag), so it can't be traded or mailed and is kept on rebirth, because the
  framework can't know which old items were bought with Robux. `itemTag = "free"` tags them
  `legacy` (tradeable, wiped on rebirth like any earned copy); use it only when the old game sold
  no items. A caller can't choose any other prefix.
- **Sold currencies stay paid:** a save field a product sold maps to a currency in
  `compliance.paidCurrencies`; `tools/test-migration` fails when a fixture's `sold` field maps to a
  currency that isn't paid, or when `itemTag = "free"` and the fixture lists a sold item.

### Status and tests

- `ctx.data.legacyStatus(player, id) -> marker?` (read-only), and the console command
  `adopt status <userId>` prints every import's marker.
- `StudWork.test.legacyStore(seed)` is an in-memory legacy store (`{ datastore = { [name] = {
  [key] = value } }, ordered = { … } }`, update times settable, with `failNext(n)`, `busy(key)` and
  `write(name, key, value, at?)` to simulate an old server), passed as `harness({ legacy = store })`
  and `sim.server(world, { legacy = store })`.

### `tools/test-migration [module] [--fixtures <dir>]`

Runs every sample old save in `<module>/tests/legacy/*.json` (or `--fixtures`) through the module's
real import in the harness. Fixtures are **synthetic** (no real player's save, user id or name).
Per fixture:

1. **Nothing lost, field by field:** every leaf of the old save is either found in the resulting
   StudWork save (by the fixture's `expect` map, e.g. `"coins": "economy.currency.Coins"`), or
   listed in the fixture's `dropped` with a reason. An old field that's neither is a failure naming
   it.
2. **Importing twice is safe:** rejoin; the save is unchanged and `import` isn't called again.
3. **A failure kicks without changing data:** with `failNext(n)` past the retries the player is
   kicked, the StudWork save is unchanged, and the next join imports.
4. **A partial old save:** the fixture with fields removed (each top-level field in turn) imports
   without an error, or fails closed (kick, nothing written); never a half import.
5. **Changed after import** (when the module has `merge`): import, then the old save changes (the
   fixture's `changed` value, written with a later time), rejoin: `merge` runs once, the result
   matches the fixture's `afterMerge` expectations, and a second rejoin changes nothing
   (idempotent). Without `merge`: the rejoin fails closed.
6. **Over the limits:** the fixture's items above the Inventory cap all arrive.
7. **Sold fields:** a `sold` field maps to a paid currency, or to items with `itemTag = "paid"`.

Exit 1 on any failure; `tools/test` runs it in a project that has legacy fixtures.

## 4. The purchase bridge (added in v1.6.0)

The rule that matters: **a purchase is granted exactly once across the switch.** Roblox re-delivers
a receipt until a server answers `PurchaseGranted`, so the dangerous receipts are the ones an old
server granted (wrote to its save) but never acknowledged. Three pieces:

### 4.1 Old receipt history in the save (`importLegacy.receipts`)

`receipts(old)` returns the PurchaseIds the old save recorded: a map of id to unix time, or a list
(then stamped with the import time). They're written in the import commit into
`_framework.legacyPurchases` (a separate map, so the 200-entry `purchases` cap never prunes them;
it keeps entries for `Legacy.RECEIPT_KEEP_DAYS` = 90 days, far past Roblox's re-delivery window).
Shop treats an id in either map as recorded: a re-delivered old receipt is a `duplicate`
(`PurchaseGranted`, handler not run), and the grant itself came over with the save.

### 4.2 An old history store (`ctx.shop.legacyReceipts`)

```lua
ctx.shop.legacyReceipts({ name = "PurchaseHistory", key = "{userId}_{purchaseId}", ["until"] = 1767225600 })
```

For games that kept history in its own DataStore (Roblox's sample pattern). Registered once per
game, in `init`. Every receipt whose PurchaseId isn't recorded is checked against the old store
**before** any handler runs (`UseCache = false`):

- a value there means the old game granted it: Shop records the id in
  `_framework.legacyPurchases`, waits for the save (like a parked duplicate), then answers
  `PurchaseGranted` (`legacy_duplicate`) without granting; a failed save answers `NotProcessedYet`;
- a read error answers `NotProcessedYet` (`legacy_check_failed`), so Roblox retries;
- nothing there: the normal flow.

`until` (optional, unix seconds) is the cutover time: once `now` is past `until` plus the
re-delivery window (`Legacy.RECEIPT_KEEP_DAYS`), the check is skipped, so an old-store outage can't
block purchases forever.

### 4.3 Old handlers through Shop, in Studio and test places (`ctx.shop.onLegacyProduct`)

```lua
ctx.shop.onLegacyProduct("CoinPack", function(receiptInfo, player)
	return OldShop.grant(receiptInfo)     -- the old handler: returns "PurchaseGranted" or "NotProcessedYet"
end, { writesLegacyData = true })
```

So old product code keeps working **while the game is being migrated**, without a second
`ProcessReceipt`. It's a development bridge, never shipped live:

- Shop still owns `ProcessReceipt`. For a legacy product it runs the duplicate checks first
  (`_framework.purchases` / `legacyPurchases`, then §4.2), then calls the old handler **outside** a
  transaction (it may yield, like the old code did).
- `"PurchaseGranted"` -> Shop records the PurchaseId and waits for the save; only then does it
  answer `PurchaseGranted`. If that save fails, the id stays recorded in memory and the answer is
  `NotProcessedYet`; the retry on this server is a `duplicate`, so the old handler isn't run twice
  here. Anything else (an error, `"NotProcessedYet"`, a non-string) answers `NotProcessedYet`.
- The old handler runs outside Compliance (no odds, no PolicyService check, no paid tag), and its
  crash window (grant done, StudWork save not yet) is the old game's own. That's why it's
  **never live**: `tools/adopt --verify` and `tools/publish --live` refuse while any
  `onLegacyProduct` call is left in the project, and the audit marks a product handler that uses
  randomness or has no history check as critical, so the plan ports those to `onProduct` first.
- **Boot error when the old handler writes the old save and an import is on:** `writesLegacyData`
  is required. If any module has an `importLegacy` and any legacy product has
  `writesLegacyData = true`, boot fails: *"legacy product CoinPack writes the old save, but <id>
  imports it (importLegacy); migrate CoinPack to ctx.shop.onProduct first"*.
- A product has one handler: `onProduct` or `onLegacyProduct`, not both (boot error).
- Every `onLegacyProduct` logs a boot warning naming the product.

Gamepasses need no bridge: ownership always comes from Roblox (`ctx.shop.ownsPass`), and perk
flags the old save kept come over with `importLegacy`.

## 5. Transitional guardrails (`studwork-legacy.json`)

An adopted game starts with old code that breaks the guardrails (raw DataStores, remotes,
balance numbers). Lint must not fail on day one, and must not let more of it in:

```json
{
  "files": [
    { "path": "src/server/SaveManager.server.luau", "checks": ["purchases", "numbers"],
      "reason": "old save code; replaced by importLegacy in plan step 3" }
  ]
}
```

- **Warn-only, with the reason:** a finding of a listed check in a listed file prints
  `warning: [legacy] <path>:<line>: [<check>] <message> (legacy: <reason>)` and doesn't fail lint.
  Findings of checks the entry doesn't list still fail.
- **Never downgraded:** an assignment to `ProcessReceipt` (Shop owns it; use §4.3), the `special`
  check (framework internals) and the `packages` check (the `studwork/` pin) fail even in a listed
  file.
- **May only shrink, per finding:** `studwork.json`'s `legacyBaseline` (written by `--init`) holds,
  per file and per check, the number of findings at init. Lint fails when a listed file has more
  findings of a check than its baseline (so new raw DataStore or remote code can't be added to a
  listed file), when `studwork-legacy.json` lists a file or a check the baseline doesn't have, or
  when the list has more entries than the baseline.
- **The baseline is anchored in git:** lint fails when `legacyBaseline` differs from the one in
  the **first** commit that ever added `studwork.json` (`git log --diff-filter=A --reverse`), so it
  can't be raised by editing it or by deleting and re-adding the file. Lint fails closed when that
  history isn't available (a shallow clone: fetch full history, as CI does). Before the first
  commit there's nothing to compare, and lint says so.
- **Stale entries:** a listed file that no longer exists fails lint ("remove it from
  studwork-legacy.json"); a listed file with no findings left warns ("nothing legacy left; remove
  the entry").
- **Every entry needs a reason** (a non-empty string), or lint fails.
- **Publishing:** `tools/publish --live` refuses while `tools/adopt --verify` fails: an entry still
  lists `purchases` (the check that covers `DataStoreService`, ProfileService/ProfileStore,
  DataStore2 and purchase callbacks: old save or purchase code still runs), an `onLegacyProduct` is
  left, a critical risk remains, or a script left in the place uses DataStores or purchases.
  `--test` is allowed. An entry the user wants to keep live (old UI code, say) stays with its
  reason.
- Projects without `adopted: true` are unaffected: there, `studwork-legacy.json` is an error
  ("only adopted projects may have a legacy list").

## 6. Rarity: odds preview at any luck, and luck on a single item (added in v1.6.0)

Two framework requests from a game whose eggs each carry their own luck (a skill score recorded
when the egg was earned).

### 6.1 Odds preview at any luck

`Rarity.getOddsDetail(tableId, player?, luck?) -> OddsDetail?` gains an optional `luck`: the odds of
the table at exactly that luck (sanitized like any luck), computed on the server and **pure**: it
doesn't change the player's luck, doesn't disclose anything, doesn't touch replication. It's for
"odds at 0 / 50 / 100%" boards. Without `luck`, the behaviour is unchanged.

### 6.2 Luck on a single item

A roll can carry its own luck for one item (an egg in an incubator), disclosed for that item:

```lua
Rarity.discloseItem(player, tableId, itemKey, luck) -> boolean  -- sends the odds for (table, item, luck)
Rarity.clearItem(player, tableId, itemKey)                      -- drops that disclosure (the egg hatched)
ctx.depsTx[Rarity].roll(tx, tableId, luck, { item = itemKey, grant = true })
```

- `discloseItem` computes the table's odds at that luck on the server and sends them through
  Compliance (`ctx.compliance.discloseItem(player, sourceId, itemKey, luck)`), which builds the
  detail itself from the source's `oddsAt(player, luck)`. The client's odds UI shows them
  (`UI.OddsTable` with the item's detail). `itemKey` is a short id string (≤ 64 chars).
- **A bounded list, never evicted:** at most `Compliance.MAX_ITEM_DISCLOSURES` = 64 item
  disclosures per player across all sources; past that `discloseItem` returns `false` and discloses
  nothing (the game clears hatched items first). Nothing is evicted behind a pending roll.
- Luck is compared **sanitized on both sides** (the value stored by `discloseItem` and the roll's
  luck go through the same sanitizer), so a disclosed luck always matches its roll.
- **Free rolls may use any luck** (unchanged): `opts.item` is only a label there.
- **A paid roll with an item key** (inside a purchase, after `spendPaid`, through `spendForRoll`, or
  on a `paid = true` table) goes through the same gate as every paid roll (PolicyService unknown ->
  retry later / `policy_unknown`; restricted -> `restricted`), and then is allowed only when
  `ctx.compliance.disclosedItem(player, sourceId, itemKey)` exists **and** its `luck` equals the
  roll's luck, and (luck ≠ 1) the table has `luckDisclosed = true`. Otherwise it's refused the same
  way as today's rule: `odds_not_disclosed` (a purchase retries later) or the hard-rule-11 error for
  undisclosed luck.
- A paid roll **without** an item key keeps today's rule (the table's disclosed luck).
- `Rarity.setLuck` is untouched; item luck never changes the player's table luck, and a roll with
  an item key ignores the player's session luck (the item's luck is the one disclosed).
- Compliance additions (any random source can use them, not only Rarity):
  `ctx.compliance.discloseItem(player, sourceId, itemKey, luck) -> boolean`,
  `ctx.compliance.disclosedItem(player, sourceId, itemKey) -> OddsDetail?`,
  `ctx.compliance.clearItem(player, sourceId, itemKey)`, the optional source field
  `oddsAt = fn(player, luck) -> OddsDetail` (a source without it can't use item disclosures), and
  `roll(tx, sourceId, luck?, opts?)` / `spendForRoll(tx, currency, amount, sourceId, luck?, opts?)`
  with `opts.item`.
- Tests at luck 1, 2.8 and 8: preview equals the math; a free item roll at each; a paid item roll
  refused before `discloseItem`, refused after `discloseItem` at another luck, allowed at the
  disclosed luck; a restricted player refused; the player's table luck unchanged throughout.

## 7. Where things live

| Piece | Files |
|---|---|
| audit, from-place, verify | `tools/adopt` (dispatcher), `tools/lune/adopt.luau`, `tools/lune/AdoptAudit.luau`, `tools/lune/AdoptPlace.luau` (+ specs) |
| init | `tools/lune/AdoptInit.luau` (+ spec), `templates/adopt/` (game-module and legacy-list templates), `tools/test-adopt` (end to end) |
| import (framework) | `packages/framework/server/Legacy.luau` (reader, read-only wrapper, formats), `Data.luau` (load step, `runImportTx`), `Context.luau` (`ctx.data.importLegacy`, `legacyStatus`, `isImport`), the test harness and sim (`legacy` option, `StudWork.test.legacyStore`) |
| test-migration | `tools/test-migration`, `tools/lune/test-migration.luau`, `tools/lune/MigrationCheck.luau` (+ spec) |
| purchase bridge | `packages/framework/server/Shop/` (`legacyReceipts`, `onLegacyProduct`, `legacyPurchases`) |
| legacy lint | `tools/lune/guardrails.luau` (legacy list handling, `--raw`, self-test), `tools/lune/PublishGate.luau` (`--live` refusal) |
| Rarity / Compliance | `packages/kits/collection/Rarity/`, `packages/framework/server/Compliance.luau` |
| playbook, docs | `AGENTS.md`, `docs/agents/adopt-existing-game.md`, `README.md` section, this page |
| fixtures | `examples/legacy/legacy-example-a` (place file), `-b`, `-c` (Rojo repos), each with synthetic `tests/legacy/*.json` sample saves |

## 8. What this design does not do

- It doesn't merge two live stores continuously (no dual-write period): the old store is frozen at
  cutover by shutting old servers down. Dual writes are exactly where double grants and lost saves
  come from.
- It doesn't import saves in bulk ahead of time (that would need Open Cloud and live data access,
  which the tools never have). Each player is imported on join.
- It doesn't migrate other players' data from global/shared stores (leaderboards, guilds): those
  are listed by the audit and handled per game (`ctx.data.shared`).
- Reading the old store on every join costs one to three DataStore reads per join for as long as
  `importLegacy` is registered. Remove the registration (keeping the markers) once the old game is
  gone for good; a later re-cutover then can't merge, which is the trade-off.
