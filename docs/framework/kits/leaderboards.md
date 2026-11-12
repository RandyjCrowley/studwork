# Engagement kit: Leaderboards

Global all-time boards (OrderedDataStore) and daily or weekly boards (MemoryStore sorted maps,
reset by the framework clock), a cached top-N, the player's own rank, and a UI kit board. Code:
`packages/kits/engagement/Leaderboards/` (`module.luau`, `server/`, `client/`; Rojo
`ReplicatedStorage.Modules.Leaderboards`, `ServerScriptService.Modules.Leaderboards`). Added in
v1.7.0 (design: [module-api.md §23](../module-api.md#23-additions-in-v170)). Entries marked
**(contract)** are part of the cross-module surface in [kit-contract.md](../kit-contract.md).

```lua
local Leaderboards = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Leaderboards"):WaitForChild("module"))
```

**Values come only from the server.** There is no client action that submits a score: a value
is read from a module's data (a built-in source), set by server code (`submit`), or produced by a
registered source function. The client only receives the rows.

## Config (`config.Leaderboards`)

| Key | Default | Meaning |
|---|---|---|
| `flag` | none | a feature flag ([environments](environments.md)); while off, nothing is written or read and the replicated boards are empty |
| `boards` | `{}` | `{ [boardId] = Board }`, below. `boardId` matches `^[%w_]{1,24}$` |
| `refreshSeconds` | `60` | how often this server re-reads each board's top N |
| `writeSeconds` | `120` | at most one write per player per board in this time (plus one on leave) |
| `utcOffsetHours` | `0` | the time zone daily and weekly periods are counted in, -14..14 |
| `weekStartsOn` | `"monday"` | `"monday"` or `"sunday"` |
| `periodKeep` | `200` | a periodic board stores at most about this many players: a value that can't reach the current `periodKeep`-th place isn't written |
| `previousPeriod` | `true` | keep the previous period readable ("last week's winners") until it expires |
| `periodGraceHours` | `24` | how long a finished period's map lives after its end |
| `names.cacheSeconds` | `3600` | display names looked up for all-time boards are cached this long |
| `backoff` | `{ base = 60, factor = 2, max = 600 }` | refresh interval after a failed read |

**Board** (`boards[boardId]`):

| Field | Default | Meaning |
|---|---|---|
| `period` | `"allTime"` | `"allTime"` (OrderedDataStore), `"daily"` or `"weekly"` (sorted map) |
| `source` | `{ kind = "submit" }` | where the value comes from: `{ kind = "submit" }` (server code calls `submit`), `{ kind = "registered" }` (a module's `registerSource`), `{ kind = "currency", currency? }` (Economy balance; needs Economy), `{ kind = "rebirths" }` (needs Rebirth), `{ kind = "streak" }` (current streak day; needs Streak) |
| `mode` | `"max"` | how a new value combines with the stored one: `"max"` (best ever / best this period), `"set"` (latest), `"sum"` (adds; for "earned today") |
| `order` | `"desc"` | `"desc"` (highest first) or `"asc"` (lowest first, e.g. fastest time) |
| `topN` | `50` | rows kept and shown, 1..100 (an OrderedDataStore page is at most 100; a sorted map range at most 200) |
| `minValue` | `1` | values below this are not written |
| `title` | `"Leaderboards.board.<boardId>"` | a string key ([localization](localization.md)); the English default is the board id until the game sets one in `GameConfig.strings` |

Values are whole numbers: OrderedDataStore stores integers, so a value is floored and must be
finite; anything else is refused with a warning naming the board. A built-in source whose module
isn't enabled is a boot error naming the board and the module to add.

## API (server)

- `submit(player, boardId, value) -> boolean`: doesn't yield. Combines `value` into the player's
  saved value for the board (by `mode`) and marks it dirty; the write follows on the next
  cadence. `false` for an unknown board, a board whose source isn't `submit`, or a bad value.
  **(contract)**
- `top(boardId, previous?) -> { rows: { { rank, userId, name, value } }, periodId?, endsAt?, updatedAt }`:
  the cached rows (frozen); doesn't yield. **(contract)**
- `rank(player, boardId) -> (rank?, value)`: the player's own value and, if they are in the
  cached top N, their rank. A rank beyond `topN` is not computed (neither store returns a rank
  cheaply); the UI shows "Top 50+" and the value. **(contract)**
- `refresh(boardId) -> boolean`: yields; an immediate re-read, still within the store budget
  (refused with `false` when over it).
- **txApi:** `submit(tx, boardId, value) -> boolean` (the value change is part of the caller's
  transaction; the write still happens on the cadence). **(contract)**
- **extensions:** `registerSource(boardId, fn(player) -> number)`: the value of a
  `{ kind = "registered" }` board, read on the write cadence. One source per board; a second
  registration errors. **(contract)**
- **signals:** `BoardRefreshed(boardId)`. **(contract)**
- **Console:** `leaderboards refresh <boardId>`, `leaderboards submit <boardId> <value> [userId]`
  (Studio or admins).

## How it uses the stores

- **All-time boards:** `ctx.data.ordered(boardId)` (§23.3). A write is `update(userId, fn)` for
  `max` (keeps the larger, so two servers can't lower a best), `set(userId, value)` for `set`,
  `increment(userId, delta)` for `sum`. The top N is `top(topN, order)`. Names: one batched
  lookup per refresh for user ids not in the name cache (`UserService:GetUserInfosByUserIdsAsync`
  through `ctx.services`, §23.6); a failed lookup shows the user id until the next refresh.
- **Daily and weekly boards:** `ctx.data.sortedMap(boardId .. "/" .. periodId)` (§23.4), key =
  user id, sort key = value, item value = `{ v = value, n = displayName }` (the name is stored with
  the score, so no lookups). Expiry = the period's end + `periodGraceHours`. The period id comes
  from the framework clock (`ctx.now()`): day = `(now + utcOffsetHours * 3600) // 86400`; week =
  the day's week starting on `weekStartsOn`. **A new period is a new map**, so the reset is the
  clock moving, not a job that has to run; the old map expires on its own.
- Writes for `max` and `sum` on periodic boards use the sorted map's atomic `update`; `periodKeep`
  skips writes that can't place, which keeps the map's memory near `periodKeep` items.
- Refresh: every `refreshSeconds` (staggered per board by a random offset at start so servers
  don't read in step), one `top` read per board. The previous period's rows are read once per
  period when `previousPeriod` is on.

**Budgets** (per server, from Roblox's limits): an OrderedDataStore list (`GetSortedAsync`) is
`5 + 2 x players` per minute, reads `60 + 40 x players`, writes `30 + 5 x players` (a `max`
write is an `UpdateAsync`: one read and one write). With the defaults one all-time board costs 1
list per minute and at most one write per player per 2 minutes, so about three all-time boards
fit the write budget of a full server with room to spare. At boot the kit warns when `allTimeBoards x 60 / refreshSeconds` exceeds 5 (the budget
of an empty server). MemoryStore costs request units against the experience-wide
`1000 + 120 x players` per minute (a range read costs one unit per row returned); the framework's
`storeBudgets` (§23.5) caps this server's share. A refused or throttled call never errors: the
kit keeps the last rows and backs off.

## Replication

- `extra.boards` (setAll): `{ [boardId] = { period, periodId?, endsAt?, title, rows, updatedAt,
  previous? } }`. **(contract)**
- `extra.mine` (per player): `{ [boardId] = { value, rank? } }`. **(contract)**
- Players receive only names, user ids and values: nothing private.

## Save data

Section `leaderboards`, version 1: `{ values = { [boardId] = number }, periods = { [boardId] =
{ id = periodId, value } }, dirty = { [boardId] = true } }`. Not replicated (the client gets
`extra.mine`). Values are the player's own; the stores hold the shared copy. A dirty value is
written after the next load if the server stopped before writing it.

## Client part and UI

- `UI.Leaderboard` (UI kit, `packages/ui/Leaderboard.luau`): props `{ title, rows, selfUserId?,
  selfValue?, selfRank?, format = "number" | "time", emptyText? }`. Theme tokens only (row
  colours from `colors.surface` / `surfaceAlt`, the player's own row `colors.leaderboardSelf`, contributed by
  this module's `theme`, default `#FFD23F`; not `leaderboardHighlight`, which the example
  SessionLeaderboard module already contributes). Every label goes through `UI.text`.
- Screen `"Leaderboards"` (`UI.registerScreen`): a tab per board, the player's own row pinned at
  the bottom when outside the top N.
- `StudWork.use(Leaderboards).board(boardId) -> rows` (client, from state) and
  `.attach(parent: Instance, boardId)`: mounts a `UI.Leaderboard` in a `SurfaceGui` the game
  placed in the world (a lobby board).

## Guardrails it relies on

- `purchases`/hard rule 4: no `DataStoreService` or `MemoryStoreService` in the kit; all store
  access is `ctx.data.ordered` / `ctx.data.sortedMap`.
- `strings` (new): the board component has no hard-coded English.
- Server authority: no client-submitted value exists to validate.

## Override levels

1. Use the defaults: list the module, define `boards`.
2. Config: periods, sizes, cadences, time zone.
3. Replace a piece: register your own `"Leaderboards"` screen, or use `UI.Leaderboard` in your own
   UI with `top`/state rows; `registerSource` for a value only your module knows.
4. Switch it off: leave it out of `modules`; the store data stays where it is.

## Failure behaviour

| Situation | Behaviour |
|---|---|
| Store read fails or is over budget | last rows stay; next try after `backoff`; `updatedAt` shows staleness |
| Write fails | the value stays dirty and is retried on the next cadence, then on the next load |
| Shutdown | `onShutdown` flushes dirty values within the store budget; the rest are written on the player's next load |
| Studio without API access | the framework's in-memory fallback with one warning (like `ctx.data.shared`) |
| Period rolls over while a server runs | the next refresh reads the new map; the old rows move to `previous` |

## Tests (mocked)

The harness backs `ctx.data.ordered` and `ctx.data.sortedMap` with in-memory stores (§23.10)
that count requests, apply the per-minute budget and inject failures; the sim shares them
between servers. Specs: `submit` modes; a client can't submit (no action exists); two servers
write and both see the merged top after `refreshSeconds`; `max` never lowers a best under
concurrent writes; a daily board resets when `h:tick` crosses midnight at `utcOffsetHours`;
`periodKeep` skips a write; budget refusal keeps the last rows; a failed write is retried on the
next load; built-in sources with and without their modules (boot error).

## Not verifiable offline

Real OrderedDataStore and MemoryStore throttling under load, name lookup latency, the 3D
board's look on devices. Live checklist in the round report.
