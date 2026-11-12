# Engagement kit: Badges

Badge definitions in config, awarded on game events, with dedupe, retries and an "awarded"
signal for UI feedback. Code: `packages/kits/engagement/Badges/` (`module.luau`, `server/`,
`client/`; Rojo `ReplicatedStorage.Modules.Badges`, `ServerScriptService.Modules.Badges`). Added in
v1.7.0 (design: [module-api.md §23](../module-api.md#23-additions-in-v170)). Entries marked
**(contract)** are part of the cross-module surface in [kit-contract.md](../kit-contract.md).

```lua
local Badges = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Badges"):WaitForChild("module"))
```

**Never awards twice. Failures never block gameplay.** An award is recorded in the player's save
the moment the trigger fires (in the triggering transaction where there is one) and sent to
Roblox afterwards, in the background; a badge recorded as awarded is never sent again, even if
the player deletes it from their profile (Roblox would allow that re-award). Nothing a player does
waits for `BadgeService`.

## Config (`config.Badges`)

| Key | Default | Meaning |
|---|---|---|
| `flag` | none | a feature flag ([environments](environments.md)); while off, triggers are still recorded as pending but nothing is sent or checked; switching it on sends the queue. An undeclared flag is a boot error |
| `badges` | `{}` | `{ [key] = { id = <badge id>, trigger = Trigger, toast = true } }`; `key` matches `^[%w_]{1,32}$`. `id = 0` is a placeholder: allowed, recorded as usual, never sent or checked. Every placeholder is named in one log line at boot (`placeholder badges (id 0): <keys>: ...`; a log line, not a warning, so a game in development boots clean), and once more as a warning per server the first time it would be sent |
| `studioFeedback` | `true` | in Studio, a record that is not sent (`awardInStudio = false`, or a placeholder id) still fires the client `Awarded` event and shows the toast, marked `Badges.awardedStudio` ("... (Studio preview, not sent)"), once per player and key per session; the record stays pending and the `BadgeAwarded` signal does not fire (it means Roblox confirmed). Lets a game see and test its badge UI. Live never does this |
| `awardInStudio` | `false` | in Studio, an award is recorded in the (Studio) save like live and logged (`would award ...`), but never sent: it stays pending. Studio saves are separate from live ones |
| `ownershipCheck` | `true` | at join, check which configured badges the player already owns or has pending (batches of 10) and record those as awarded without sending |
| `retry` | `{ base = 5, factor = 2, max = 300, attempts = 6 }` | backoff between send attempts; after `attempts` failures in a session the badge stays pending for the next session |
| `budget.perMinute` | `{ base = 40, perPlayer = 28 }` | this server's award calls per minute: 80% of Roblox's `AwardBadgeAsync` limit (`50 + 35 x players`), leaving room for any other code that awards through `ctx.services.get("BadgeService")` |
| `budget.checksPerMinute` | `{ base = 10, perPlayer = 5 }` | ownership checks per minute (`CheckUserBadgesAsync`: `10 + 5 x players`) |
| `infoCacheSeconds` | `3600` | how long a badge's info (`IsEnabled`, name) is cached per server |

**Trigger** (`trigger.kind`):

| Kind | Fields | Fires when | Needs |
|---|---|---|---|
| `"manual"` | none | game code calls `award(player, key)` | none |
| `"join"` | none | the player's first load (`ctx.framework.sessions(player) == 1`) | none |
| `"streak"` | `atLeast` | Streak's `StreakAdvanced` reaches `atLeast` | Streak |
| `"rebirths"` | `atLeast` | Rebirth's `count(player)` (at join) or the `Rebirthed` count reaches `atLeast` | Rebirth |
| `"item"` | `item` | Inventory's `ItemAdded` with that item id | Inventory |
| `"currency"` | `currency?`, `atLeast` | Economy's `CurrencyChanged` balance reaches `atLeast` | Economy |
| `"leaderboard"` | `board`, `rank` | the player is at or above `rank` on a board refresh | Leaderboards |

Triggers on a module that isn't enabled are a boot error naming the badge and the module (so are
a bad key, id, kind or trigger field). All of them are declared `optional` dependencies, so the
kit itself needs none. A trigger that is already satisfied at join (a streak of 10 for a badge at
7, a balance, an item already owned, a rank, a rebirth count read with `Rebirth.count(player)`)
fires on load, after every module's own load handlers.

## API (server)

- `award(player, key) -> boolean`: doesn't yield. Records the badge as awarded (if it isn't
  already) and queues the send. `true` if it was newly recorded. Unknown key: errors (a typo is a
  bug). **(contract)**
- `has(player, key) -> boolean`: recorded as awarded (by us or found owned). Doesn't yield.
  **(contract)**
- **txApi:** `award(tx, key) -> boolean`: records the award inside the caller's transaction; the
  send follows only after the transaction commits (`tx.after`). Use it when the award belongs
  to the same change as the reason ("bought the first upgrade"). The same function is the
  module's `purchaseOps.award`, so a product handler calls `tx.use(Badges).award(key)`.
  **(contract)**
- **signals:** `BadgeAwarded(player, key, badgeId)`: fires once Roblox confirmed the award (or
  it was found already owned), never on a mere record. A found badge gets the signal and the
  client event, but no toast. **(contract)**
- **Console:** `badges list [userId]`, `badges pending [userId]`, `badges reset <key> [userId]`
  (Studio only: clears our record; never removes anything from Roblox).

## The flow

1. **Record.** A trigger or `award` writes `awarded[key] = { at, sent = false }` in the
   player's section (in its own tx, or the caller's). Already recorded: nothing happens.
2. **Queue.** After the commit, the key goes on this server's send queue for that player.
3. **Send** (a background thread, one per server, within `budget.perMinute`):
   `GetBadgeInfoAsync(id)` (cached `infoCacheSeconds`); a disabled badge is skipped with one
   warning per server and stays pending. Then `AwardBadgeAsync(userId, id)` in `pcall`.
   - `true`: `sent = true`, `BadgeAwarded` fires, a toast (`Badges.awarded` string) if `toast`.
   - `false` (Roblox returns it for a badge the player already owns, among other cases): one
     `CheckUserBadgesAsync` for that badge (within `budget.checksPerMinute`); owned: recorded as
     `{ sent = true, found = true }` and `BadgeAwarded` fires; not owned: as an error.
   - an error: backoff and retry; after `attempts`, left pending for the next session.
   - the player left: left pending (Roblox only awards to players in the server).
4. **Join.** With `ownershipCheck`, configured badges not yet recorded **and pending ones** are
   checked with `CheckUserBadgesAsync` (10 per call, within `budget.checksPerMinute`); owned ones
   are recorded as `{ sent = true, found = true }` without an award call (a crash between the award
   and the save, or a badge awarded before the game used this module, can't loop). The remaining
   pending badges are queued again. The result is cached for the session.

## Save data and replication

Section `badges`, version 1: `{ awarded = { [key] = { at, sent, found? } } }`. Replicated `data`:
`awarded` (the client shows earned badges; keys and times only). The badge ids live in config.

## Client part

The toast is sent by the server through the framework feedback when Roblox confirms an award
(`toast = true`), text `Badges.awarded` with `{ name }` = the badge's name string key
`Badges.badge.<key>`, formatted in the player's language (English default: the key, from the
module's `strings` function, §23.9; games set real names in `GameConfig.strings`). The client
part adds `StudWork.use(Badges).earned() -> { [key]: boolean }` (every recorded badge, from
state) and `StudWork.use(Badges).onAwarded(fn(key)) -> Connection` (the server-fired module event
`Awarded(key)`, for a game's own effect with `toast = false`).

## Guardrails it relies on

- The award is never inside a purchase handler's critical path: product handlers may call
  `txApi.award`, which only records.
- `ctx.services.get("BadgeService")` (§23.6) is the only route to the engine service, so tests
  substitute a fake.
- Server only: the client has no action that awards anything.

## Override levels

1. Use the defaults: list the module, set `badges` with ids and triggers.
2. Config: budgets, retries, toast per badge.
3. Replace a piece: `manual` triggers from your own module; listen to `BadgeAwarded` for your own
   effect and set `toast = false`.
4. Switch it off: leave it out of `modules`; the section is kept, nothing is sent.

## Failure and budget behaviour

| Situation | Behaviour |
|---|---|
| BadgeService errors or rate limit | backoff, then pending to the next session; gameplay never waits |
| Badge disabled on the dashboard | skipped, stays pending, one warning per server |
| Over `budget.perMinute` | queued until the next minute |
| Player leaves mid-queue | stays pending; queued again on their next join |
| Studio (`awardInStudio = false`) | recorded in the Studio save, logged, never sent (stays pending); the client still gets `Awarded` and a toast marked as a Studio preview once per session (`studioFeedback`); the join ownership check still reads |
| Placeholder `id = 0` | recorded, never sent or checked; named in one log line at boot, then one warning per server on first use |

## Tests (mocked)

`StudWork.test.fakes.badgeService({ owned = { [userId] = { badgeIds } }, disabled = { ids },
failNext = n })` passed as `harness({ services = { BadgeService = fake } })`. Specs: each trigger
kind; never twice (two triggers, a rejoin, a fake that reports "already owned"); a failure retries
with backoff and survives a rejoin; budget queueing; a disabled badge stays pending; ownership
check batches of 10 and records found badges without an award call; a pending badge the fake
reports as owned (award returns `false`) is recorded as found and stops retrying, at join and on
send; a placeholder id is never sent; `txApi.award` in a discarded transaction records nothing;
`BadgeAwarded` fires only after the fake confirmed.

## Not verifiable offline

Real `AwardBadgeAsync` results and Roblox's own badge notification, the per-minute limits under
load, and badge ownership checks for players who recently left. Live checklist: [manual-qa.md](../../manual-qa.md), "New in v1.7.0".
