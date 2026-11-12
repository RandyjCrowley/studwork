# Engagement kit: Leaderboards

Global all-time boards (OrderedDataStore) and daily or weekly boards (MemoryStore sorted maps,
reset by the framework clock), a top N shared by every server, the player's own rank, and a UI kit
board. Code: `packages/kits/engagement/Leaderboards/` (`module.luau`, `server/`, `client/`; Rojo
`ReplicatedStorage.Modules.Leaderboards`, `ServerScriptService.Modules.Leaderboards`). Added in
v1.7.0 (design: [module-api.md §23](../module-api.md#23-additions-in-v170)). Entries marked
**(contract)** are part of the cross-module surface in [kit-contract.md](../kit-contract.md).

```lua
local Leaderboards = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Leaderboards"):WaitForChild("module"))
```

**Values come only from the server.** There is no client action that submits a score: a value
is read from a module's data (a built-in source), set by server code (`submit`), or produced by a
registered source function. The client only receives the rows.

## Quick start

In `GameConfig.modules` add `Leaderboards`. Needs no other module for a `submit` board.

```lua
-- GameConfig.config
Leaderboards = { boards = { bestScore = { period = "allTime", mode = "max" } } },  -- or "daily" / "weekly"
-- game module (server): the value only ever comes from the server
Leaderboards.submit(player, "bestScore", 120)            -- written on the cadence (writeSeconds)
local top = Leaderboards.top("bestScore")                -- { rows = { { rank, userId, name, value } } }
-- spec (mirrored by KitQuickStarts.spec.luau): the harness needs a UserService fake for the names
local h = StudWork.test.harness({ modules = { Leaderboards }, services = { UserService = StudWork.test.fakes.userService() },
	config = { Leaderboards = { boards = { bestScore = { mode = "max" } } } } })
local api = h:use(Leaderboards); h:tick(121); api.refresh("bestScore")
```

## Config (`config.Leaderboards`)

| Key | Default | Meaning |
|---|---|---|
| `flag` | none | a feature flag ([environments](environments.md)); while off, nothing is written or read and the replicated boards are empty |
| `boards` | `{}` | `{ [boardId] = Board }`, below. `boardId` matches `^[%w_]{1,24}$` |
| `refreshSeconds` | `60` | the shortest interval between two reads of a board's shared top N by this server, and the age at which the shared top N is re-read from the store |
| `topReadsPerMinute` | `6000` | target reads of one board's shared top N per minute across all servers: with many servers each server reads less often (below) |
| `writeSeconds` | `120` | at most one write per player per board in this time (plus one on leave) |
| `utcOffsetHours` | `0` | the time zone daily and weekly periods are counted in, -14..14 |
| `weekStartsOn` | `"monday"` | `"monday"` or `"sunday"` |
| `cutToTop` | `true` | a periodic `max` or `sum` write is skipped while the board's top N is full and the value doesn't beat its last row (the cut in the shared top N); keeps the period maps small |
| `previousPeriod` | `true` | keep the previous period readable ("last week's winners") until it expires |
| `periodGraceHours` | `24` | how long a finished period's maps live after its end (at most 24, so a weekly board stays inside MemoryStore's 8-day quota window, §23.5) |
| `names.cacheSeconds` | `3600` | display names looked up for all-time boards are cached this long |
| `backoff` | `{ base = 60, factor = 2, max = 600 }` | refresh interval after a failed read |

**Board** (`boards[boardId]`):

| Field | Default | Meaning |
|---|---|---|
| `period` | `"allTime"` | `"allTime"` (OrderedDataStore), `"daily"` or `"weekly"` (sorted maps) |
| `source` | `{ kind = "submit" }` | where the value comes from: `{ kind = "submit" }` (server code calls `submit`), `{ kind = "registered" }` (a module's `registerSource`), `{ kind = "currency", currency? }` (Economy balance; needs Economy), `{ kind = "rebirths" }` (needs Rebirth), `{ kind = "streak" }` (current streak day; needs Streak) |
| `mode` | `"max"` | how a new value combines with the player's saved one: `"max"` (the better by `order`: best ever / best this period; the larger for `"desc"`, the smaller for `"asc"`), `"set"` (latest), `"sum"` (adds; for "earned today"; needs a `submit` source, since a built-in source reports a total) |
| `order` | `"desc"` | `"desc"` (highest first) or `"asc"` (lowest first, e.g. fastest time) |
| `topN` | `50` | rows kept and shown, 1..100 (an OrderedDataStore page is at most 100) |
| `minValue` | `1` | values below this are not written |
| `shards` | `1` | periodic boards only: the period's scores are split over this many sorted maps (`userId % shards`), 1..16, to spread writes over map partitions (sizing below) |
| `title` | `"Leaderboards.board.<boardId>"` | a string key ([localization](localization.md)); the module's `strings` function gives each board the English default = the board id, until the game sets one in `GameConfig.strings` |

Values are whole numbers: OrderedDataStore stores integers, so a value is floored and must be
finite; anything else is refused with a warning naming the board. A built-in source whose module
isn't enabled is a boot error naming the board and the module to add, and so is any other bad
board field (period, mode, order, `topN`, `shards`, a `shards` above 1 on an all-time board, a
source kind), with the board's id in the message. A `flag` the game never declared is a boot error
too. The `rebirths` source reads `Rebirth`'s `count(player)` (v1.7.0), so a player's count is known from
the join; the `Rebirthed` signal only keeps this server's cached count current.

## API (server)

- `submit(player, boardId, value) -> boolean`: doesn't yield. Combines `value` into the player's
  saved value for the board (by `mode`) and marks it dirty; the write follows on the next
  cadence. `false` for an unknown board, a board whose source isn't `submit`, a bad value, a
  player whose save isn't loaded, or while the board's `flag` is off. **(contract)**
  On a `max` or `sum` board the value is combined in memory first and joins the save in one update
  per player within 30 s (on the player's own staggered phase), before each store write, on leave
  and on shutdown, so submitting every tick costs no save transaction per call; `rank` and
  `extra.mine` include it at once. A `max` value that doesn't beat the saved best changes nothing.
  `set` boards go straight into the save (their order matters).
- `top(boardId, previous?) -> { rows: { { rank, userId, name, value } }, periodId?, endsAt?, updatedAt }`:
  the cached rows (frozen); doesn't yield. **(contract)**
- `rank(player, boardId) -> (rank?, value)`: the player's own value (0 when they have none yet,
  or none in the current period) and, if they are in the cached top N, their rank. A rank beyond `topN` is not computed (neither store returns a rank
  cheaply); the UI shows "Top 50+" and the value. **(contract)**
- `refresh(boardId) -> boolean`: yields; re-reads the shared top N now (and re-reads the store if
  it is older than `refreshSeconds`), still within the store budgets (`false` when over them).
- **txApi:** `submit(tx, boardId, value) -> boolean` (the value change is part of the caller's
  transaction; the write still happens on the cadence). **(contract)**
- **extensions:** `registerSource(boardId, fn(player) -> number)`: the value of a
  `{ kind = "registered" }` board, read on the write cadence. One source per board; a second
  registration errors. **(contract)**
- **signals:** `BoardRefreshed(boardId)`: fires when this server's rows for the board changed.
  **(contract)**
- **Console:** `leaderboards refresh <boardId>`, `leaderboards submit <boardId> <value> [userId]`
  (Studio or admins).

## How it uses the stores

**The player's save holds the authoritative value** (one session lock, one writer): the all-time
total or best in `values`, this period's in `periods`. Every store write sends that value and is
**idempotent**, so a retried write, a timed-out call that actually committed, or a re-send after a
crash can't count twice. The kit never calls `increment`.

- **All-time boards:** `ctx.data.ordered(boardId)` (§23.3). `max` and `sum` write
  `update(userId, function(old) return math.max(old or 0, value) end)` (keeps the larger, so two
  servers can't lower a best and a stale re-send can't undo a newer total); `set` writes
  `set(userId, value)`.
- **Daily and weekly boards:** `ctx.data.sortedMap(boardId .. "/" .. periodId .. "/" .. shard)`
  (§23.4), `shard = userId % shards`, key = user id, sort key = value, item value
  `{ v = value, n = displayName }` (the name is stored with the score, so no lookups). Writes are
  `update`: `max(old.v, value)` for `max` and `sum`, `value` for `set`. Expiry = the period's end +
  `periodGraceHours`. The period id comes from the framework clock (`ctx.now()`): day =
  `(now + utcOffsetHours * 3600) // 86400`; week = the day's week starting on `weekStartsOn`. **A new
  period is a new map**, so the reset is the clock moving, not a job that has to run; the old map
  expires on its own.
- **The shared top N:** one sorted map per board, `ctx.data.sortedMap("top/" .. boardId)`, one item
  per period (key `periodId`, or `"all"`): `{ rows = { { u, n, v } }, at, cut?, lease = { by, untilAt }? }`
  (`cut` = the `topN`-th value once the board is full). Expiry: the period's end + grace; for
  all-time `max(10 x refreshSeconds, 3600)` s, renewed by each re-read.

**Refresh (one elected reader per board):** every refresh interval (the first one staggered per board by a
random offset of up to a tenth of `refreshSeconds` after start) a server `get`s the board's top item: 1 request unit. If the item is older
than `refreshSeconds`, has no live lease, and this server has the budget for the source read, it
takes the lease with an atomic `update` (lease 30 s; the update cancels when another server got
there first), reads the source (all-time: one `top(topN, order)` list plus one batched name lookup
for ids not in its cache, `UserService:GetUserInfosByUserIdsAsync` through `ctx.services`, §23.6;
periodic: `range` of `topN` from each shard, merged), and writes the item back with `at = now`.
Every other server just reads the item. A failed name lookup shows the user id until the next
re-read.

A server's refresh interval is `max(refreshSeconds, 60 x servers / topReadsPerMinute)` seconds,
with `servers` from the framework census (`ctx.data.census()`, §23.5; until the first census,
`refreshSeconds`). So each board's top map gets about `topReadsPerMinute` reads a minute at most,
whatever the number of servers, and its store is read about once per `refreshSeconds` for the
whole experience.

**Budgets and scaling** (from Roblox's limits):

- *Per server, OrderedDataStore* (`5 + 2 x players` lists, `60 + 40 x players` reads,
  `30 + 5 x players` writes per minute; a `max` write is an `UpdateAsync`: one read and one write):
  only the elected reader lists, so lists are rare; writes are at most one per player per board
  per `writeSeconds`. The framework refuses ordered calls near the limit (`storeBudgets`, §23.5).
- *Per experience, OrderedDataStore* (list `300 + 2 x CCU`, write `300 + 20 x CCU` per minute,
  shared with Open Cloud): lists are about `60 / refreshSeconds` per board per minute in total;
  writes about `CCU x 60 / writeSeconds` per board per minute, so each board uses at most about a
  fortieth of the write limit at the defaults. An experience-level throttle backs off the whole
  module's store use (§23.3), not one call.
- *MemoryStore request units* (experience-wide `1000 + 120 x CCU` per minute; a range costs one
  unit per row returned plus one): each server caps its own use (`storeBudgets.memoryUnits`).
- *MemoryStore partitions:* each sorted map is one partition, and Roblox starts throttling at about
  30,000 units a minute on one partition (100,000 on one structure). A period map receives about
  `CCU x 60 / writeSeconds / shards` writes a minute (only changed values are written). **Size
  `shards` so this stays under about 10,000:** at the default `writeSeconds` that is one shard per
  20,000 concurrent players. The top map is bounded by `topReadsPerMinute`.
- *MemoryStore memory* (experience-wide `64 KB + 1.2 KB x users`): a period item is about 60 bytes,
  a top item about `topN x 40` bytes. A period map holds every player whose value beat the cut when
  they wrote: everyone who scored while the board was still filling, then only those who place, so
  roughly the number of players active early in the period plus those who reached the top. The
  module's writes count against its `storeBudgets.memory` share (§23.5): a write refused with
  `"memory_budget"` stays dirty and is retried; the board then lags, nothing else stops.

A refused or throttled call never errors: the kit keeps the last rows and backs off.

## Replication

- `extra.boards` (setAll): `{ [boardId] = { period, periodId?, endsAt?, title, rows, updatedAt,
  previous? } }`; `rows` are `{ rank, userId, name, value }`, `title` is a string key (the client
  resolves it with `UI.text`, so it follows the player's language), `periodId` is the day index
  of the period's first day. **(contract)**
- `extra.mine` (per player): `{ [boardId] = { value, rank? } }`, refreshed after each write and
  each refresh. **(contract)**
- Players receive only names, user ids and values: nothing private.

## Save data

Section `leaderboards`, version 1: `{ values = { [boardId] = number }, periods = { [boardId] =
{ id = periodId, value } }, dirty = { [boardId] = true } }`. Not replicated (the client gets
`extra.mine`). Values are the player's own and authoritative; the stores hold the shared copy. A
dirty value is written after the next load if the server stopped before writing it (safe: writes
are idempotent). A submitted `max` or `sum` value reaches the section within 30 s, or on leave or
shutdown (above); only a server crash inside that window loses it, as it loses anything since the
last autosave.

## Client part and UI

- `UI.Leaderboard` (UI kit, `packages/ui/Leaderboard.luau`): props `{ title, rows, selfUserId?,
  selfValue?, selfRank?, format = "number" | "time", emptyText?, size?, layoutOrder? }`. Numbers
  read with thousands separators, `"time"` as `m:ss` / `h:mm:ss` (`packages/ui/LeaderboardFormat.luau`).
  The player's own row is highlighted in the list or, outside it, pinned under it with the rank
  or "Top N+". Theme tokens only (row colours
  from `colors.surface` / `surfaceAlt`, the player's own row `colors.leaderboardSelf`, default
  `#FFD23F`, in the **base theme** so the component works with or without this module; not
  `leaderboardHighlight`, which the example SessionLeaderboard module already contributes). Names
  are rendered with `AutoLocalize = false`. Every label goes through `UI.text`.
- Screen `"Leaderboards"` (`UI.registerScreen`): a tab per board, the player's own row pinned at
  the bottom when outside the top N.
- `StudWork.use(Leaderboards).board(boardId) -> rows` (client, from state), `.mine(boardId) ->
  { value, rank? }?`, `.open(boardId?, options?)` (opens the screen; `options.formats =
  { [boardId] = "number" | "time" }`) and `.attach(parent: Instance, boardId, options?) -> () ->
  ()`: mounts a `UI.Leaderboard` in a `SurfaceGui` the game placed in the world (a lobby board)
  and returns a function that unmounts it (`options = { format?, title? }`). `.read` holds the pure
  state readers. The screen is registered at start unless the game registered its own first.

## Guardrails it relies on

- `purchases`/hard rule 4: no `DataStoreService` or `MemoryStoreService` in the kit; all store
  access is `ctx.data.ordered` / `ctx.data.sortedMap`.
- `strings`: the board component has no hard-coded English.
- Server authority: no client-submitted value exists to validate.

## Override levels

1. Use the defaults: list the module, define `boards`.
2. Config: periods, sizes, shards, cadences, time zone.
3. Replace a piece: register your own `"Leaderboards"` screen, or use `UI.Leaderboard` in your own
   UI with `top`/state rows; `registerSource` for a value only your module knows.
4. Switch it off: leave it out of `modules`; the store data stays where it is.

## Failure behaviour

| Situation | Behaviour |
|---|---|
| Store read fails or is over budget | last rows stay; next try after `backoff`; `updatedAt` shows staleness |
| The elected reader stops mid-read | its lease expires after 30 s; the next server that finds the item stale reads |
| Write fails or the memory share is full | the value stays dirty and is retried on the next cadence, then on the next load |
| Shutdown | `onShutdown` puts every pending submit into the save, then flushes dirty values within the store budget; the rest are written on the player's next load |
| Leave | pending submits go into the save before the leave write, so nothing accepted is lost |
| Studio without API access | the framework's in-memory fallback with one warning (like `ctx.data.shared`) |
| A name lookup fails | the rows show the user id with one warning per board until the next read; nothing else stops |
| The `flag` is off | nothing is written or read, `submit` returns `false`, `top` is empty and the replicated boards are `{}` until it is on again |
| Period rolls over while a server runs | the next refresh reads the new period's top item; the old rows move to `previous` |

## Tests (mocked)

Specs: `packages/kits/engagement/tests/Leaderboards*.spec.luau` (harness: `Leaderboards`,
`LeaderboardsBoards`, `LeaderboardsPending` (in-memory submits: leave, shutdown, periods, txApi, idle ticks); pure rules: `LeaderboardsPure`; client: `LeaderboardsClient`; sim:
`LeaderboardsSim`; the sandbox wiring: `LeaderboardsDemo`), `Leaderboards/client/State.spec.luau`
and `packages/ui/Leaderboard.spec.luau`.

The harness backs `ctx.data.ordered` and `ctx.data.sortedMap` with in-memory stores (§23.10)
that count requests, apply the budgets and Roblox's per-structure limits, and inject failures; the
sim shares them between servers. Specs: `submit` modes; a client can't submit (no action exists);
two servers write and both see the merged top after `refreshSeconds`; only one of them reads the
store per refresh (the lease); `max` never lowers a best under concurrent writes; a repeated or
re-sent `sum` write doesn't double count; a daily board resets when `h:tick` crosses midnight at
`utcOffsetHours`; `cutToTop` skips a write that can't place; a sharded board merges its shards;
budget refusal keeps the last rows; a failed write is retried on the next load; built-in sources
with and without their modules (boot error); many sim servers keep the top map near
`topReadsPerMinute`.

## Not verifiable offline

Real OrderedDataStore and MemoryStore throttling under load, name lookup latency, the 3D
board's look on devices. Live checklist: [manual-qa.md](../../manual-qa.md), "New in v1.7.0".
