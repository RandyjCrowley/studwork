# Engagement kit: Notifications

Experience notifications that bring players back: an opt-in prompt shown at a good moment (never
on join), notification templates in config, and sends triggered by game events ("your egg is
ready", "your streak ends in 4 hours"). Code: `packages/kits/engagement/Notifications/`
(`module.luau`, `server/`, `client/`, `net.blink`; Rojo `ReplicatedStorage.Modules.Notifications`,
`ServerScriptService.Modules.Notifications`). Added in v1.7.0 (design:
[module-api.md §23](../module-api.md#23-additions-in-v170)). Entries marked **(contract)** are part
of the cross-module surface in [kit-contract.md](../kit-contract.md).

```lua
local Notifications = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Notifications"):WaitForChild("module"))
```

## Quick start

Add `Notifications` to `GameConfig.modules`, the allow-list to `ServerConfig` ([Setup](#setup-the-key-and-the-allow-list)).

```lua
-- GameConfig.config
Notifications = { templates = { comeBack = { messageId = "123456" } } },   -- "" = placeholder, never sent
-- game module (server)
Notifications.suggestOptIn(player, "firstHatch")                          -- a good moment to ask
Notifications.schedule(player.UserId, "comeBack", os.time() + 6 * 3600)
-- spec (NotificationsQuickStart.spec.luau): isStudio = true needs sendInStudio, else it only logs
local h = StudWork.test.harness({ modules = { Notifications }, isStudio = true, openCloud = fake,
	secrets = { OpenCloudNotifications = true }, serverConfig = ServerConfig,   -- the openCloud allow-list
	config = { Notifications = { templates = { comeBack = { messageId = "123456" } }, sendInStudio = true,
		quiet = { startHour = 0, endHour = 0 }, optIn = { minSessions = 0 } } } })   -- 0: a brand-new player can be prompted
local api = h:use(Notifications)
local p = h:addPlayer({ userId = 1 })
h:tick(181)                                    -- minSessionSeconds (180): no prompt before it
expect(api.suggestOptIn(p, "firstHatch")).toBe(true)
expect(api.schedule(p.UserId, "comeBack", h.clock + 6 * 3600)).toBe(true)
```

Both waits matter: `optIn.minSessions` (default 1) counts finished sessions, and
`optIn.minSessionSeconds` (default 180) is the time in this session before a prompt.

## How the platform works (and what it doesn't do)

- **Opt-in is Roblox's prompt, on the client.** `ExperienceNotificationService:CanPromptOptInAsync()`
  then `PromptOptIn()`, both client-only. Roblox doesn't show it to under-13s, to players who
  already enabled notifications, or to anyone it was shown to in the last 30 days. Its text can't be
  changed. `OptInPromptClosed` fires with no result: **the experience never learns whether the
  player opted in.**
- **Sending is Open Cloud** (`POST https://apis.roblox.com/cloud/v2/users/{userId}/notifications`),
  which a game server can call through `HttpService` with an API key read from the experience's
  secrets store (`HttpService:GetSecret`). The kit sends through the framework's
  `ctx.openCloud` (§23.7), which only lets it use the secret, method and path the game allowed
  for it ([Setup](#setup-the-key-and-the-allow-list)); the key never appears in code, config or logs.
- **Roblox decides delivery.** Only opted-in players aged 13+ get notifications, at most **one per
  day per experience**, and its spam system may drop more. The experience must have 100+ visits and
  not be under moderation.
- **There is no scheduling.** A notification goes out when it is sent. A notification for a future
  time ("your egg hatches at 18:00") needs a running server of the experience at that time: the
  kit keeps a due list in MemoryStore sorted maps and running servers send the due entries (see
  [Scheduled sends](#scheduled-sends)). With no server running, the send happens when the next
  server polls, or is dropped once it is older than `schedule.staleAfterHours`.
- **No PolicyService field covers notifications.** Age and region rules are enforced by Roblox
  (prompt and delivery). The kit honours them by never working around them: it never asks for
  opt-in outside Roblox's prompt and never gates gameplay on it.
- **Content rules:** templates are personal and actionable, never ads, never false time pressure
  (a "streak ends soon" message is only sent when it is true). Roblox filters and moderates the text.

## Setup: the key and the allow-list

1. Create an Open Cloud API key on the Creator Dashboard with **only** the user notifications
   write permission (`user.user-notification:write`) for this experience's universe, nothing else
   ([guide](https://create.roblox.com/docs/cloud/guides/experience-notifications); check the
   permission's name on the Dashboard when you create the key). A key with more scopes would let
   any code holding the secret do more; the framework's allow-list below is the second fence.
2. Add it to the experience's secrets store under the name in `config.Notifications.secret`
   (default `OpenCloudNotifications`), and turn on "Allow HTTP Requests".
3. Allow the module to use it, in **`ServerConfig`** (server-only, never replicated; §23.7):

```lua
-- ServerConfig
openCloud = {
	secrets = {
		OpenCloudNotifications = { modules = { "Notifications" }, methods = { "POST" }, paths = { "users/*/notifications" } },
	},
},
```

Without step 3 every send returns `(false, "not_allowed")` and the server logs once which entry
is missing. No key, URL or secret value goes in the repo.

## The request

`ctx.openCloud.request` with the configured secret, `POST users/<userId>/notifications` and this body
(names follow the Open Cloud reference; the live checklist re-checks them). Only the template and
`params` go in; a player's name or text never does.

```lua
{ source = { universe = "universes/<ctx.env.universeId()>" },
  payload = { type = "MOMENT", messageId = tpl.messageId,
              parameters = { [name] = { stringValue = v } | { int64Value = "<userId>" } },   -- when the template has any
              joinExperience = { launchData = "sw1:<templateKey>" },                          -- when `launch`
              analyticsData = { category = tpl.category } } }
```

## Config (`config.Notifications`)

| Key | Default | Meaning |
|---|---|---|
| `flag` | none | a feature flag name ([environments](environments.md)); while it is off the kit sends and prompts nothing (a live kill switch) |
| `secret` | `"OpenCloudNotifications"` | name of the secrets-store entry holding the API key ([Setup](#setup-the-key-and-the-allow-list)). Missing: the kit logs once and every send returns `(false, "no_secret")` |
| `sendInStudio` | `false` | in Studio, sends are logged (`would send <templateKey> to <userId>`, never the params) and not made, even with a local secret |
| `templates` | `{}` | `{ [key] = Template }`, below; `key` matches `^[%w_]{1,32}$` |
| `optIn.minSessionSeconds` | `180` | never prompt before this much play in the current session (never on join) |
| `optIn.minSessions` | `1` | sessions the player must have finished before the first prompt (0 = the first session may prompt, after `minSessionSeconds`) |
| `optIn.cooldownDays` | `30` | days between our prompts for one player (Roblox also limits to one per 30 days) |
| `optIn.maxPrompts` | `3` | prompts per player, ever |
| `optIn.onSuggest` | `true` | prompt when game code calls `suggestOptIn` (the "good moment"); `false` = only templates' `promptOnSchedule` |
| `limits.perPlayerPerDay` | `1` | sends per recipient per UTC day (Roblox's own limit is 1; more only wastes Open Cloud requests) |
| `limits.minGapHours` | `20` | hours between two sends to one recipient |
| `limits.perServerPerMinute` | `60` | sends this server makes per minute (Open Cloud allows 2500 per server per minute in total) |
| `limits.perActorPerDay` | `10` | sends and schedules one player can cause per UTC day, when the call names them as `actor` (counted in that player's save, so it holds on every server); over it: `(false, "actor_limit")` |
| `quiet.startHour` / `quiet.endHour` | `22` / `8` | the recipient's local quiet hours (their offset as below); (wrapping midnight when start > end; equal = none); a send due inside them waits until `endHour` (a wait that takes an entry past `schedule.staleAfterHours` after its original time drops it) |
| `quiet.defaultUtcOffsetHours` | `0` | used when the recipient's offset is unknown (the client reports its offset, -14..14; [Quiet hours](#quiet-hours) says when it is known). Set it to your main audience's offset (e.g. `-5` for a mostly US East game) |
| `schedule.shards` | `4` | the due list and the ledger are split into this many sorted maps (`userId % shards`), 1..32, so no single map partition carries every server's traffic |
| `schedule.pollSeconds` | `30` | the shortest interval between two polls by one server (each poll reads one shard, in turn) |
| `schedule.pollsPerShardPerMinute` | `20` | target polls per shard per minute across all servers: with many servers each server polls less often (below) |
| `schedule.batch` | `20` | due entries read per poll (MemoryStore request units = entries returned + 1) |
| `schedule.leaseSeconds` | `90` | how long a claim keeps an entry out of the due window: one send attempt plus the ledger writes (45..600) |
| `schedule.staleAfterHours` | `12` | a due entry older than this is dropped, not sent (its time plus this is also its MemoryStore expiry, so an unpolled entry disappears by itself and stops counting against `maxPerPlayer`) |
| `schedule.maxAheadHours` | `168` | `schedule` further ahead than this is refused (`"too_far"`); keeps every entry inside MemoryStore's 8-day quota window (§23.5) |
| `schedule.maxPerPlayer` | `5` | scheduled entries one recipient can have waiting (enforced in the shared ledger, so it holds for offline recipients too) |
| `retry` | `{ base = 30, factor = 2, max = 900, attempts = 4 }` | backoff for a failed send (429, 5xx, network); 4xx other than 429 is not retried. The attempt count lives in the due entry, so any server continues it |

**Template** (`templates[key]`):

| Field | Default | Meaning |
|---|---|---|
| `messageId` | required | the notification string's asset id from the Creator Dashboard (Engagement > Notifications): letters, digits and dashes, at most 64 characters (anything else, such as a stray space, is a template error at boot: a warning, and the template is ignored). `""` is a placeholder: allowed, scheduled and limited as usual, never sent (`send` answers `(false, "placeholder")` after the recipient's limits; a due placeholder entry is cleared without a send or a count). Every placeholder is named in one log line at boot (`placeholder templates (messageId = ""): <keys>: ...`; a log line, not a warning, so a game in development boots clean), and once more as a warning on its first use |
| `params` | `{}` | the parameters the string uses: `{ [name] = "string" | "userId" }` (a `userId` parameter is a `{userId-...}` mention; a plain list of names means all `"string"`). Names are words of at most 32 characters |
| `category` | the key | Open Cloud `analyticsData.category` |
| `launch` | `true` | include launch data so the join is attributed (`LaunchedFrom` signal, analytics) |
| `cooldownHours` | `24` | hours before this template can go to the same player again |
| `cancelOnJoin` | `true` | a scheduled send of this template is cancelled when the player joins any server first |
| `promptOnSchedule` | `false` | scheduling this template for a player who is online counts as a good moment to prompt opt-in |
| `hoursBefore` | `4` | `streakEnding` only: hours before the end of Streak's grace window |
| `minStreak` | `3` | `streakEnding` only: no reminder for a streak shorter than this (keeps the due list small) |

## API (server)

- `send(userId, templateKey, params?, actor?) -> (ok, reason?)`: yields. Sends now, after the limits,
  quiet hours (a send inside quiet hours is scheduled for `endHour` instead: `(true, "scheduled")`)
  and the `flag`. A retryable failure (429, 5xx, network) goes on the due list with its attempt
  count and returns `(true, "queued")`; any server continues it. Reasons: `"disabled"` (the `flag` is off, or no template is configured),
  `"no_secret"`, `"not_allowed"` (the `ServerConfig.openCloud` allow-list), `"placeholder"`,
  `"unknown_template"`, `"bad_params"` (also a bad user id or key), `"rate_limited"` (per recipient: the day
  count, the gap, or another server's send in flight), `"server_budget"`, `"studio"` (Studio without
  `sendInStudio`: logged, not sent),
  `"cooldown"` (the template's `cooldownHours`), `"memory_budget"` (the module's MemoryStore share is full,
  §23.5), `"store_busy"`,
  `"failed"` (after retries), `"refused"` (a 4xx from Open Cloud), `"actor_limit"` (below). Never
  errors for a platform failure. **(contract)**
- `actor` (optional, `send` and `schedule`; added after the design freeze): the player whose action
  caused this send, loaded on this server (not loaded: `"bad_params"`). A call that goes ahead
  (`ok == true`) counts against that player's `limits.perActorPerDay`; over it the call answers
  `(false, "actor_limit")` and touches nothing of the recipient's. The other limits are per
  recipient and per server, so without it one player wired to `send(targetId, ...)` could spend
  every target's daily send (`perPlayerPerDay`) and stop the game's own notifications reaching them.
  **A recipient chosen by a client is untrusted:** check it first (a friend with
  `ctx.deps[Friends]`, a player on this server, someone who opted in to hearing from them), never
  just a number from an action, and pass the sender as `actor`.
- `schedule(userId, templateKey, at, params?, key?, actor?) -> (ok, reason?)`: yields. Queues a send for
  unix time `at` (framework clock). `key` (default `templateKey`) replaces an earlier entry of
  the same key for that user: rescheduling "egg ready" moves it, it doesn't add a second one.
  Extra reasons: `"too_far"`, `"too_many"` (`maxPerPlayer`), `"memory_budget"`. Works for offline
  recipients (it never touches their save). **(contract)**
- `cancel(userId, key) -> boolean`: yields. **(contract)**
- `suggestOptIn(player, reason) -> (boolean, reason?)`: game code says "now is a good moment" (the
  player just started something that finishes later). `player` is a live `Player` (an Instance).
  The server checks the opt-in rules and, if they pass, tells that player's client to run Roblox's
  check and prompt. Returns whether a prompt was requested and, when not, why: `"not_suggested"`
  (`optIn.onSuggest` is false), `"too_early"`, `"sessions"`, `"max_prompts"`, `"cooldown"`,
  `"pending"`, `"asked"` (the opt-in rules above), `"disabled"`, `"no_event"`, `"not_loaded"`,
  `"save_failed"`, `"bad_params"`. Doesn't yield. A platform-restricted player is refused on the
  client (`CanPromptOptInAsync`), which reports `shown = false`. **(contract)**
- Signals: `Sent(userId, templateKey)`, `OptInPrompted(player)`, `LaunchedFrom(player,
  templateKey)` (a join from a notification's Join button). **(contract)** `LaunchedFrom` comes
  from `GetJoinData().LaunchData`, which share links and invites can also set: it is **untrusted**,
  for attribution and analytics only. Never grant a reward from it.

`params` values are strings, or numbers for `"userId"` params. They are not player text: never put
player-entered text in a notification (Roblox filters it again, but it can't be targeted to the
recipient's settings; the `textfilter` lint check flags it). Validation: every name in the
template's `params` present, nothing extra, strings at most 100 characters. **Params are never
logged or sent to analytics** (they may name players); logs and analytics carry the template key,
the category and the reason.

## Quiet hours

A recipient's local time is UTC plus their offset. The offset used, first found wins:

1. a due entry's own `o` (recorded when it was scheduled);
2. the recipient's saved `utcOffset`, if they are on this server (their client reports it once a
   session, `setUtcOffset`);
3. the `o` in their ledger entry (below): every ledger write made while they are on a server
   records it there, and their `setUtcOffset` and leaving refresh an entry that already exists. This
   is what reaches a recipient who is on no server;
4. `quiet.defaultUtcOffsetHours`.

So the recipient's own quiet hours apply while they have a ledger entry: any send in the last 48 h
(or the longest `cooldownHours`), or any waiting scheduled entry. **A recipient with no ledger entry
gets the default:** someone never notified, or not for two days, who is on no server. No entry is
created just to remember an offset, on purpose: one per player who leaves would need far more than
the module's memory share (at 1,000 concurrent users with 30-minute sessions that is about 96,000
items over two days, about 5 MB, against a share of about 300 KB). Set
`quiet.defaultUtcOffsetHours` to your main audience. Scheduling a reminder when a player leaves
(the usual `comeBack` pattern) creates their entry with their offset.

## Scheduled sends

**Where entries live.** Two families of sorted maps, sharded by `s = userId % schedule.shards`:

- the due list `ctx.data.sortedMap("due/" .. s)` (§23.4): key `<userId>/<key>`, sort key = the time
  the entry may next be tried (`nextAt`), value `{ k = templateKey, p = params?, o = utcOffset?,
  at = dueAt, n = attempts? }` (compact: no field that has its default), expiry =
  `at + staleAfterHours`;
- the per-recipient ledger `ctx.data.sortedMap("ledger/" .. s)`: key `userId`, value
  `{ d = day, c = countToday, l = lastSentAt, t = { [templateKey] = lastSentAt }, q = { [key] = dueAt },
  r = { by = jobId, untilAt }?, o = utcOffset? }` ([Quiet hours](#quiet-hours)), expiry = the longest of 48 h, the longest template `cooldownHours` and the last
  waiting entry's `at + staleAfterHours` (read first, written with that expiry; if another server adds a
  later entry in between, the update cancels itself and goes round again).

**Scheduling** is two atomic updates: the ledger first (refuses `"too_many"` when `q` already has
`maxPerPlayer` other keys; records `q[key] = at`), then the due entry (replacing one with the same
key). `cancel` and `cancelOnJoin` remove both (the ledger key first, which also
tells `cancel` whether anything was waiting). A `schedule` whose due write fails takes its ledger key
back out. A key whose due entry expired is forgotten by the ledger on its next write. The player's save holds none of this, so limits and
cancellation work the same for offline recipients.

**Polling.** Each server polls one shard per poll, rotating from a random start. Its interval is
`max(pollSeconds, 60 x servers / (shards x pollsPerShardPerMinute))` seconds, with `servers` from
the framework census (`ctx.data.census()`, §23.5; until the first census, `pollSeconds`). So each
shard is read about `pollsPerShardPerMinute` times a minute whatever the number of servers, and the
due list's request rate doesn't grow with the server count. A poll is
`range("asc", batch, nil, { sortKey = now })`.

**Sending a due entry:**

1. **Claim** with an atomic `update` on the entry: only if its sort key is still `<= now`; it sets
   the sort key to `now + leaseSeconds` (and `c = jobId`). A claimed entry has left the due window,
   so the next poll by any server reads the entries behind it: a stuck or failing head can't block
   the list.
2. **Reserve** the recipient with an atomic `update` on the ledger: refused when a send would break
   `perPlayerPerDay`, `minGapHours` or the template's `cooldownHours`, or another server holds a live
   reservation `r`. A refused entry is re-keyed to the time it becomes allowed (or dropped if that is
   past `staleAfterHours`). Quiet hours are applied here too, with the offset as in
   [Quiet hours](#quiet-hours) (the ledger's `o` when the entry has none).
3. **Send** one Open Cloud request.
4. **Not an Open Cloud answer.** `"not_allowed"`, `"no_secret"` and this server's own Open Cloud rate
   (`"budget"`) mean nothing was sent: nothing counts, the reservation is given back, the entry waits
   (`retry.base` for the rate, `retry.max` for a setup problem) and no attempt is used.
5. **2xx:** the ledger is updated (count, `lastSentAt`, template time, `r` cleared, `q[key]`
   removed), then the due entry is removed. **The ledger counts a send only after Open Cloud
   accepted it.** A definitive failure (4xx other than 429): `r` and `q[key]` cleared, entry
   removed, `NotificationFailed`. A retryable failure: `r` cleared, the entry's `n` incremented and
   its sort key set to `now + backoff(n)`; after `retry.attempts`, removed with `NotificationFailed`.

A crash between claim and send leaves the entry claimed until `leaseSeconds` pass, then any server
retries it; the reservation `r` expires at the same time. A duplicate needs a crash between Open
Cloud's reply and the ledger write; Roblox's own one-per-day limit then absorbs it. Delivery is
at least once per due entry while servers run, and never more than the limits for a recipient
except in that crash window.

**Memory** (MemoryStore's quota is experience-wide, `64 KB + 1.2 KB x concurrent users`): a due
entry is about 80 bytes (key, compact value, sort key), a ledger entry about 60 bytes plus 20 per
waiting key. The module's writes count against its `storeBudgets.memory` share (§23.5): when the
share is full, `schedule` returns `"memory_budget"` and the built-in `streakEnding` reminder is
skipped quietly. Example: at 1,000 concurrent users the quota is about 1.2 MB; the default share
(0.25) is about 300 KB, room for about 2,500 waiting entries with their ledgers. With a high
daily-to-concurrent player ratio, raise the share or `minStreak`.

**`send` uses memory too.** Every recipient who was sent anything keeps a ledger entry for at least
48 hours (the day count and the gap need it; longer with a longer `cooldownHours`). Charged at about
120 bytes each (key, value and the 32-byte item overhead, §23.4), the default share at 1,000
concurrent users holds about 2,500 recipients notified in the last two days, fewer with waiting
entries. Past that, `send` answers `"memory_budget"` too (nothing is
sent: a send the ledger can't count could break the per-recipient limits). A game that notifies
many distinct players a day should raise `storeBudgets.memory.shares.Notifications`.

**The poll needs no setup.** A poll with no usable key pushes each entry it reads back `retry.max`
seconds, so the entries behind them are read; in Studio with `sendInStudio = false` it logs `would send`
and clears the entries. The Studio console has `notifications poll` to read one shard now.

## Client part

- Listens for the module's `PromptOptIn(requestId)` event. On it: `pcall(CanPromptOptInAsync)`;
  if true, `PromptOptIn()`; then the action `optInShown(requestId, shown: boolean)` reports whether
  Roblox's prompt was shown (rate limit 1/s, burst 2). The server accepts it only for the
  outstanding `requestId` it sent that player (then clears it; a request older than five minutes is
  ignored) and records `lastPromptAt`; `prompts` counts only prompts Roblox showed, so a player Roblox
  won't prompt (under 13, already opted in) is checked again only after `optIn.cooldownDays`. At most one
  request per player per session.
- Reports the device's UTC offset once per session with the action `setUtcOffset(hours)`
  (`os.date("*t")` vs `os.date("!*t")`, rounded to 0.25 h, rate limit 1 per 10 s): it only moves
  sends out of quiet hours.
- `StudWork.use(Notifications).canPrompt() -> boolean?` (the last client check, nil = not
  checked yet).
- The client part reaches `ExperienceNotificationService` through a small seam
  (`client/OptIn.luau` takes the service table), so client specs pass a fake.

## Save data and replication

Section `notifications`, version 1:
`{ lastPromptAt = 0, prompts = 0, sessions = 0, utcOffset = nil, promptRequest = nil, lastLaunchDay = 0 }`
(`promptRequest`: the outstanding prompt's id and time). Replicated `data`: none. Replicated
`extra`: none. Scheduled entries are in the shared ledger, not the save; sends to offline players
never touch their save.

On join: `sessions += 1` (`optIn.minSessions` counts the sessions *before* the current one); the player's ledger `q` is read and every waiting key whose template has
`cancelOnJoin` is cancelled (in a spawned thread, after load); the join data is read with
`player:GetJoinData()` and parsed strictly: `LaunchData` must be `sw1:<templateKey>` (at most 200
bytes) naming a configured template, anything else is ignored. A valid one fires `LaunchedFrom`
and, at most once per player per UTC day (`lastLaunchDay`), the analytics event
`NotificationJoin` (category).

## Integrations (optional)

- **Streak** (optional): template key `streakEnding` is built in when Streak is enabled and the
  game defines that template: on leave, if the player's streak is at least `minStreak` and would
  reset before they could return, a send is scheduled `hoursBefore` before the end of Streak's
  grace window, using `Streak.expiresAt(player)` (a v1.7.0 addition to Streak's API,
  [kit-contract.md](../kit-contract.md)). Cancelled on join; skipped quietly when the memory share
  is full.
- A reminder time inside the recipient's quiet hours waits for `endHour` (the entry is re-keyed).
- Game modules schedule their own: on "egg started", `schedule(userId, "eggReady", readyAt)`.

## Guardrails it relies on

- `remotes`: the client prompt and reports go through the module's own `net.blink` actions.
- No secret in the repo: the key name is config, the key is in the secrets store, and the
  `ServerConfig.openCloud` allow-list limits the module to one method and path.
- `textfilter`: `send`/`schedule` params are a sink for player text.
- Analytics (`ctx.analytics.custom`): `NotificationSent`, `NotificationFailed` (reason),
  `NotificationPrompted`, `NotificationJoin`. Never params. The framework's analytics call needs a player,
  so these are sent when the recipient is on the sending server; every outcome is also one log line
  (template key, user id, reason).

## Override levels

1. Use the defaults: list the module, define `templates`, add the secret and the allow-list entry.
2. Config: limits, quiet hours, opt-in rules, shards, `flag`.
3. Replace a piece: call `suggestOptIn` from your own moments; set `optIn.onSuggest = false` and
   prompt only through `promptOnSchedule`.
4. Switch it off: leave it out of `modules`. Calls through `StudWork.use` error clearly; modules
   that declared it `optional` skip it with `ctx.isEnabled`.

## Failure and budget behaviour

| Situation | Behaviour |
|---|---|
| Secret missing, HTTP requests disabled, Studio local playtest without a local secret | one log line on the first send or due entry that needs it, `send` -> `(false, "no_secret")`, no error, gameplay unchanged |
| Secret not allowed for the module in `ServerConfig.openCloud` | one log line naming the missing entry, `(false, "not_allowed")`, no request made |
| Placeholder `messageId = ""` | limits and scheduling run as usual, nothing sent, `(false, "placeholder")`; named in one log line at boot, then one warning per server on first use |
| Open Cloud 429 / 5xx / network | the entry goes (back) on the due list with its attempt count and backoff; `send` returns `(true, "queued")`; after the last attempt, analytics `NotificationFailed` |
| Open Cloud 4xx (bad message id, not eligible) | not retried, `(false, "refused")`, analytics `NotificationFailed` |
| MemoryStore over this server's request budget or throttled | the poll skips a round (the due list keeps); `schedule` returns `(false, "store_busy")` |
| The module's memory share is full | `schedule` returns `(false, "memory_budget")`; `streakEnding` skipped quietly |
| No server running at the due time | sent by the next server that polls, unless older than `staleAfterHours` |
| `CanPromptOptInAsync` fails | no prompt; reported as not shown |

**The request-unit cap sets how many a server can send.** Every ledger and due-list call is a
MemoryStore call and counts against the server's cap, `storeBudgets.memoryUnits` =
`base + perPlayer x players` per minute (default 20 + 20 per player, [module-api §23.5](../module-api.md)).
A send costs about 6 units (reserve, send, record) and a due entry about 9, so a server with no
players (20 units a minute) sends about 3 notifications a minute, and each player in the server adds
about 3 more. Over the cap a call answers `store_busy` and a due entry waits for the next minute, or
for another server. A game that sends many notifications from servers with few players should raise
`storeBudgets.memoryUnits.base` (known issue O9).

## Tests (mocked; nothing calls Roblox)

- `StudWork.test.fakes.openCloud()` records every request (method, path, body, the secret's
  **name**) and answers from a script (`respond(status, body)`, `failNext(n, status)`).
  `harness({ openCloud = fake, secrets = { OpenCloudNotifications = true }, serverConfig = { openCloud = ... } })`.
- The due list and ledger run on the harness's in-memory sorted maps (§23.10); the sim shares them
  between servers.
- **Running the poll in a spec.** There is no poll call on the API (the `notifications poll`
  console command is Studio-only); the server part polls from its 1-second tick, once every
  `schedule.pollSeconds` (30), reading **one shard per poll** in turn (`schedule.shards`, 4). The
  first poll comes at a random point within the first `pollSeconds`. `h:tick(n)` advances the clock
  one second at a time and runs the ticks, so after the due time:

  ```lua
  -- config.Notifications.schedule = { shards = 1 } keeps it to one shard
  api.schedule(userId, "comeBack", h.clock + 6 * 3600)
  h.clock += 6 * 3600                -- jump to the due time (no need to tick through the wait)
  h:tick(30 + 1)                     -- at least one poll: pollSeconds + 1
  -- with the default 4 shards: h:tick(4 * 30 + 1), so every shard is read once
  expect(#openCloudFake.requests).toBe(1)
  ```

  A jump of the clock leaves the next poll due, so the first tick after it polls; every further
  poll needs another `pollSeconds` of ticks. With a `census` that reports many servers the interval
  grows (`max(pollSeconds, 60 x servers / (shards x pollsPerShardPerMinute))`, above). A due entry
  inside the recipient's quiet hours is moved to their `endHour`, not sent, so pick due times in
  open hours (or set `quiet = { startHour = 0, endHour = 0 }`, no quiet hours).
- **A complete scheduled-send harness** (Studio server, so `sendInStudio = true`; `quiet` off so any
  due time is open; the allow-list in `serverConfig`; `schedule.shards = 1`). Without any one of them
  the fake sees 0 requests. Run as a spec in `NotificationsQuickStart.spec.luau`:

  ```lua
  local h = StudWork.test.harness({
  	modules = { Notifications }, isStudio = true, openCloud = openCloudFake,
  	secrets = { OpenCloudNotifications = true },
  	serverConfig = { openCloud = { secrets = { OpenCloudNotifications = {
  		modules = { "Notifications" }, methods = { "POST" }, paths = { "users/*/notifications" } } } } },
  	config = { Notifications = { templates = { comeBack = { messageId = "123" } },
  		sendInStudio = true, quiet = { startHour = 0, endHour = 0 }, schedule = { shards = 1 } } },
  })
  ```

- **A new player and the opt-in.** `optIn.minSessions` (default 1) counts *finished* sessions, so a
  fresh `h:addPlayer` is never prompted with the defaults: set `optIn = { minSessions = 0 }` (or
  `h:rejoin(p)` once). Then `h:tick(181)` passes `minSessionSeconds`.
- **The opt-in without stubbing the part.** The harness gives the part a recording `net`
  (testing.md), so no hand-made part is needed:

  ```lua
  expect(api.suggestOptIn(p, "egg")).toBe(true)
  local asked = h:sent("Notifications", "PromptOptIn")      -- { { event, player, args = { requestId } } }
  expect(#asked).toBe(1)
  h:action(p, Notifications, "optInShown", asked[1].args[1], true)   -- the client's answer
  ```

  Guide: [testing.md](../testing.md).
- Specs drive the whole flow: `suggestOptIn` before `minSessionSeconds` (refused) and after
  (client event fired); `optInShown` with the right and a wrong `requestId`; `send` within/over the
  limits; quiet hours move a send; `schedule` + `h:tick` past the due time + poll -> one Open Cloud
  request with the documented body; `maxPerPlayer` for an offline recipient; `cancelOnJoin`; a
  missing secret and a missing allow-list entry log once and never error; a placeholder
  `messageId` sends nothing; a row another server claimed after this one read it is not sent; the client part with a fake `ExperienceNotificationService` (can
  prompt / can't / errors); a forged `LaunchData` fires nothing.
- Sim specs: two servers poll, one send; a server that stops after its claim (the other sends after
  `leaseSeconds`); a 5xx then a 2xx on another server (attempt count carried, ledger counted once);
  a failing head entry doesn't block the entries behind it; many servers keep each shard near
  `pollsPerShardPerMinute`; a full MemoryStore quota (`TotalMemoryOverLimit`) returns `"memory_budget"` while another
  module's map still writes (the module's own share, §23.5, is the stores' budget spec).

## Not verifiable offline

The real Open Cloud response shapes and error codes, whether a non-opted-in recipient gives an
error or a silent success, actual delivery, the launch data round trip (`GetJoinData`), and the
prompt's look. These are on the live checklist in [manual-qa.md](../../manual-qa.md).
