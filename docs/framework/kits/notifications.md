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

## How the platform works (and what it doesn't do)

- **Opt-in is Roblox's prompt, on the client.** `ExperienceNotificationService:CanPromptOptInAsync()`
  then `PromptOptIn()`, both client-only. Roblox doesn't show it to under-13s, to players who
  already enabled notifications, or to anyone it was shown to in the last 30 days. Its text can't be
  changed. `OptInPromptClosed` fires with no result: **the experience never learns whether the
  player opted in.**
- **Sending is Open Cloud** (`POST https://apis.roblox.com/cloud/v2/users/{userId}/notifications`),
  which a game server can call through `HttpService` with an API key read from the experience's
  secrets store (`HttpService:GetSecret`). The kit sends through the framework's
  `ctx.openCloud` (§23.7); the key never appears in code, config or logs.
- **Roblox decides delivery.** Only opted-in players aged 13+ get notifications, at most **one per
  day per experience**, and its spam system may drop more. The experience must have 100+ visits and
  not be under moderation.
- **There is no scheduling.** A notification goes out when it is sent. A notification for a future
  time ("your egg hatches at 18:00") needs a running server of the experience at that time: the
  kit keeps a due list in a MemoryStore sorted map and every server sends the due entries (see
  [Scheduled sends](#scheduled-sends)). With no server running, the send happens when the next
  server starts, or is dropped once it is older than `schedule.staleAfterHours`.
- **No PolicyService field covers notifications.** Age and region rules are enforced by Roblox
  (prompt and delivery). The kit honours them by never working around them: it never asks for
  opt-in outside Roblox's prompt and never gates gameplay on it.
- **Content rules:** templates are personal and actionable, never ads, never false time pressure
  (a "streak ends soon" message is only sent when it is true). Roblox filters and moderates the text.

## Config (`config.Notifications`)

| Key | Default | Meaning |
|---|---|---|
| `flag` | none | a feature flag name ([environments](environments.md)); while it is off the kit sends and prompts nothing (a live kill switch) |
| `secret` | `"OpenCloudNotifications"` | name of the secrets-store entry holding an Open Cloud API key allowed to create user notifications for this experience ([guide](https://create.roblox.com/docs/cloud/guides/experience-notifications)). Missing: the kit logs once and every send returns `(false, "no_secret")` |
| `sendInStudio` | `false` | in Studio, sends are logged (`would send ...`) and not made, even with a local secret |
| `templates` | `{}` | `{ [key] = Template }`, below |
| `optIn.minSessionSeconds` | `180` | never prompt before this much play in the current session (never on join) |
| `optIn.minSessions` | `1` | sessions the player must have finished before the first prompt (0 = the first session may prompt, after `minSessionSeconds`) |
| `optIn.cooldownDays` | `30` | days between our prompts for one player (Roblox also limits to one per 30 days) |
| `optIn.maxPrompts` | `3` | prompts per player, ever |
| `optIn.onSuggest` | `true` | prompt when game code calls `suggestOptIn` (the "good moment"); `false` = only templates' `promptOnSchedule` |
| `limits.perPlayerPerDay` | `1` | sends per recipient per UTC day (Roblox's own limit is 1; more only wastes Open Cloud requests) |
| `limits.minGapHours` | `20` | hours between two sends to one recipient |
| `limits.perServerPerMinute` | `60` | sends this server makes per minute (Open Cloud allows 2500 per server per minute in total) |
| `quiet.startHour` / `quiet.endHour` | `22` / `8` | the recipient's local quiet hours; a send due inside them waits until `endHour` |
| `quiet.defaultUtcOffsetHours` | `0` | used when the player's offset is unknown (the client reports its offset, -14..14) |
| `schedule.pollSeconds` | `30` | how often each server reads the due list |
| `schedule.batch` | `20` | due entries read per poll (MemoryStore request units = entries returned) |
| `schedule.staleAfterHours` | `12` | a due entry older than this is dropped, not sent |
| `schedule.maxPerPlayer` | `5` | scheduled entries one player can have waiting |
| `retry` | `{ base = 30, factor = 2, max = 900, attempts = 4 }` | backoff for a failed send (429, 5xx, network); 4xx other than 429 is not retried |

**Template** (`templates[key]`):

| Field | Default | Meaning |
|---|---|---|
| `messageId` | required | the notification string's asset id from the Creator Dashboard (Engagement > Notifications) |
| `params` | `{}` | parameter names the string uses, each `"string"` or `"userId"` (a `{userId-...}` mention) |
| `category` | the key | Open Cloud `analyticsData.category` |
| `launch` | `true` | include launch data so the join is attributed (`LaunchedFrom` signal, analytics) |
| `cooldownHours` | `24` | hours before this template can go to the same player again |
| `cancelOnJoin` | `true` | a scheduled send of this template is cancelled when the player joins any server first |
| `promptOnSchedule` | `false` | scheduling this template for a player who is online counts as a good moment to prompt opt-in |

## API (server)

- `send(userId, templateKey, params?) -> (ok, reason?)`: yields. Sends now, after the limits,
  quiet hours (a send inside quiet hours is scheduled for `endHour` instead: `(true, "scheduled")`)
  and the `flag`. A retryable failure (429, 5xx, network) is retried in the background with
  `retry` and returns `(true, "queued")`. Reasons: `"disabled"`, `"no_secret"`, `"unknown_template"`, `"bad_params"`,
  `"rate_limited"` (per recipient), `"server_budget"`, `"cooldown"`, `"failed"` (after retries),
  `"refused"` (a 4xx from Open Cloud). Never errors for a platform failure. **(contract)**
- `schedule(userId, templateKey, at, params?, key?) -> (ok, reason?)`: yields. Queues a send for
  unix time `at` (framework clock). `key` (default `templateKey`) replaces an earlier entry of
  the same key for that user: rescheduling "egg ready" moves it, it doesn't add a second one.
  **(contract)**
- `cancel(userId, key) -> boolean`: yields. **(contract)**
- `suggestOptIn(player, reason) -> boolean`: game code says "now is a good moment" (the player
  just started something that finishes later). The server checks the opt-in rules and, if they
  pass, tells that player's client to run Roblox's check and prompt. Returns whether a prompt was
  requested. Doesn't yield. **(contract)**
- Signals: `Sent(userId, templateKey)`, `OptInPrompted(player)`, `LaunchedFrom(player,
  templateKey, data)` (a join from a notification's Join button; `data` is the template's launch
  payload). **(contract)**

`params` values are strings, or numbers for `"userId"` params. They are not player text: never put
player-entered text in a notification (Roblox filters it again, but it can't be targeted to the
recipient's settings). Validation: every name in the template's `params` present, nothing extra,
strings at most 100 characters.

## Scheduled sends

The due list is one MemoryStore sorted map per experience (`ctx.data.sortedMap("due")`, §23.4):
key `<userId>/<key>`, sort key = the due time, value `{ template, params, at }`, expiry =
`at + staleAfterHours` (at most the 45-day MemoryStore maximum). Every `pollSeconds` each server
reads at most `batch` entries due by now (`range` ascending, upper bound = now), **claims** each
with an atomic update (it writes `claimedBy = <jobId>, claimedAt`; an entry claimed less than
`2 * pollSeconds` ago is skipped), sends it and removes it. A crash after the claim and before
the send drops nothing: the claim expires and another server retries; a crash after the send and
before the remove can send twice, which the per-recipient ledger then refuses
(`limits.minGapHours`). Delivery is therefore at most one per recipient per gap, at least once
per due entry while servers run.

The per-recipient ledger is a second sorted map (`ctx.data.sortedMap("ledger")`, key `userId`,
expiry 48 h): `{ day, count, lastAt, byTemplate }`, updated atomically before each send, so the
limits hold across servers and for offline recipients (whose save this server can't write).

## Client part

- Listens for the module's `PromptOptIn` event. On it: `pcall(CanPromptOptInAsync)`; if true,
  `PromptOptIn()`; then the action `optInShown(shown: boolean)` reports whether Roblox's prompt
  was shown (rate limit 1/s, burst 2), and the server records `lastPromptAt` / `prompts`.
- Reports the device's UTC offset once per session with the action `setUtcOffset(hours)`
  (`os.date("*t")` vs `os.date("!*t")`, rounded to 0.25 h, rate limit 1 per 10 s): it only moves
  sends out of quiet hours.
- `StudWork.use(Notifications).canPrompt() -> boolean?` (the last client check, nil = not
  checked yet).
- The client part reaches `ExperienceNotificationService` through a small seam
  (`client/OptIn.luau` takes the service table), so client specs pass a fake.

## Save data and replication

Section `notifications`, version 1:
`{ lastPromptAt = 0, prompts = 0, sessions = 0, utcOffset = nil, scheduled = {} }`
(`scheduled`: the keys this player has waiting, for `maxPerPlayer` and for `cancelOnJoin`).
Replicated `data`: none. Replicated `extra`: none. Sends to offline players never touch their save.

On join: `sessions += 1`; every `scheduled` key whose template has `cancelOnJoin` is cancelled
(in a spawned thread, after load); the join data is read with `player:GetJoinData()` and a
`LaunchedFrom` signal plus the analytics event `NotificationJoin` (category) fire for a join from
a notification.

## Integrations (optional)

- **Streak** (optional): template key `streakEnding` is built in when Streak is enabled and the
  game defines that template: on leave, if the player's streak would reset before they could
  return, a send is scheduled `hoursBefore` (template field, default 4) before the end of
  Streak's grace window, using `Streak.expiresAt(player)` (a v1.7.0 addition to Streak's API,
  [kit-contract.md](../kit-contract.md)). Cancelled on join.
- Game modules schedule their own: on "egg started", `schedule(userId, "eggReady", readyAt)`.

## Guardrails it relies on

- `remotes`: the client prompt and reports go through the module's own `net.blink` actions.
- No secret in the repo: the key name is config, the key is in the secrets store.
- Analytics (`ctx.analytics.custom`): `NotificationSent`, `NotificationFailed` (reason),
  `NotificationPrompted`, `NotificationJoin`.

## Override levels

1. Use the defaults: list the module, define `templates`, add the secret.
2. Config: limits, quiet hours, opt-in rules, `flag`.
3. Replace a piece: call `suggestOptIn` from your own moments; set `optIn.onSuggest = false` and
   prompt only through `promptOnSchedule`.
4. Switch it off: leave it out of `modules`. Calls through `StudWork.use` error clearly; modules
   that declared it `optional` skip it with `ctx.isEnabled`.

## Failure and budget behaviour

| Situation | Behaviour |
|---|---|
| Secret missing, HTTP requests disabled, Studio local playtest without a local secret | one log line at start, `send` -> `(false, "no_secret")`, no error, gameplay unchanged |
| Open Cloud 429 / 5xx / network | retried with `retry` backoff in a background thread; `send` returns `(true, "queued")`; after the last attempt, analytics `NotificationFailed` |
| Open Cloud 4xx (bad message id, not eligible) | not retried, `(false, "refused")`, analytics `NotificationFailed` |
| MemoryStore over budget or throttled | the poll skips a round (the due list keeps); `schedule` returns `(false, "store_busy")` |
| No server running at the due time | sent by the next server that polls, unless older than `staleAfterHours` |
| `CanPromptOptInAsync` fails | no prompt; reported as not shown |

## Tests (mocked; nothing calls Roblox)

- `StudWork.test.fakes.openCloud()` records every request (method, path, body, the secret's
  **name**) and answers from a script (`respond(status, body)`, `failNext(n, status)`).
  `harness({ openCloud = fake, secrets = { OpenCloudNotifications = true } })`.
- The due list and ledger run on the harness's in-memory sorted maps (§23.10); the sim shares them
  between servers, so "two servers poll, one send" is a sim spec.
- Specs drive the whole flow: `suggestOptIn` before `minSessionSeconds` (refused) and after
  (client event fired); `optInShown` updates the save; `send` within/over the limits; quiet hours
  move a send; `schedule` + `h:tick` past the due time + poll -> one Open Cloud request with the
  documented body; `cancelOnJoin`; a missing secret logs once and never errors; the client part
  with a fake `ExperienceNotificationService` (can prompt / can't / errors).

## Not verifiable offline

The real Open Cloud response shapes and error codes, whether a non-opted-in recipient gives an
error or a silent success, actual delivery, the launch data round trip (`GetJoinData`), and the
prompt's look. These are on the live checklist in the round report.
