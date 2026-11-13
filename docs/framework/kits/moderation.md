# Moderation kit: Admin, Moderation, Reports

Three modules for keeping a game safe: **Admin** (who is staff, what each role may do, the staff
panel), **Moderation** (bans, kicks, mutes, warnings, offence ladders, the audit log) and
**Reports** (players report players; staff work a queue). Code:
`packages/kits/moderation/<Module>/` (`module.luau`, `server/`, `client/`, `net.blink`; Rojo
`ReplicatedStorage.Modules.<Module>`, `ServerScriptService.Modules.<Module>`), kit specs in
`packages/kits/moderation/tests/`. Each module declares `framework = "^1.7.0"` and version
`"1.0.0"`. Every config key, default, reason and status below is the one in the modules' code
(`module.luau` and `server/`); the shared-file changes the kit needs (CHANGELOG, module-api §24,
kit contract, decisions) are listed in [docs/pending/moderation.md](../../pending/moderation.md)
until the release merges them. Entries marked **(contract)** are part of the cross-module surface
proposed for [kit-contract.md](../kit-contract.md).

```lua
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Admin = require(Modules:WaitForChild("Admin"):WaitForChild("module"))
local Moderation = require(Modules:WaitForChild("Moderation"):WaitForChild("module"))
local Reports = require(Modules:WaitForChild("Reports"):WaitForChild("module"))
```

**Every decision is the server's.** A client can ask for a staff action, but the server checks
that the sender is staff first and drops a request from anyone who isn't exactly as it drops an
unknown action. Who is staff is never replicated to other players. Reporters are never named to
the reported player, to any non-staff client, or to staff without `reports.reporters`. Every
free-text field a **staff member or player** types (report notes, announcements, free ban and
kick messages, private reasons) is filtered through [TextFilter](textfilter.md) at submission, or
refused. Text your own server code passes (`by = "server"`, `"console"`, `"system"`) is treated as
developer text and is not filtered: never pass player-typed text with a trusted actor.

## Quick start

In `GameConfig.modules` add `Admin`, `Moderation` and `Reports` (any subset works, see below), and
name your staff in `ServerConfig` (server-only; clients never receive it). Add
[TextFilter](textfilter.md) too if staff should type free text or players should add notes.

```lua
-- GameConfig.modules
require(Modules:WaitForChild("Admin"):WaitForChild("module")),      -- staff roles, permissions, the staff panel
require(Modules:WaitForChild("Moderation"):WaitForChild("module")), -- bans, kicks, mutes, warnings, audit log
require(Modules:WaitForChild("Reports"):WaitForChild("module")),    -- player reports and the staff queue

-- ServerConfig.luau (ServerScriptService): generic example ids
Admin = {
	users = { [1001] = "owner", [1002] = "moderator" },          -- userId -> role
	groups = {
		{ groupId = 2001, roles = {
			{ roleId = 3001, role = "admin" },                     -- a stable role id (preferred)
			{ minRank = 100, role = "helper" },                    -- or a minimum public rank
		} },
	},
},

-- GameConfig.strings: the appeal line every ban message ends with (no handles, no direct links)
["Moderation.ban.appeal"] = "Appeal on our group page.",

-- Balance.luau: TextFilter refuses input longer than its maxLength (default 40). Raise it if
-- report notes (Reports.note.maxLength 120) or announcements (Admin.announce.maxLength 200)
-- should get through.
TextFilter = { maxLength = 200 },
```

**Trying the kit before it is released.** A game pins StudWork at a release tag, and
`tools/new-project --tag` accepts only a tag that exists in the `--url` repo, so a kit that is still
on a branch can't be pinned directly (a `--ref` option is proposed in the pending file). Until then:
clone the branch locally (`git clone --branch <branch> <studwork-url> studwork-src`), make a local
annotated tag in that clone only (`git -C studwork-src tag -a v1.7.99 -m "local trial"`; never
push it), and run `studwork-src/tools/new-project <path> --url studwork-src --tag v1.7.99`.
Throw the project away once the release tag exists; never publish a game pinned to a local tag.

```lua
-- spec sketch (the kit's real specs: packages/kits/moderation/tests/*.spec.luau)
-- path from this repo's root; from a game see "Tests (mocked)" below (studwork/... and (require :: any))
local Fakes = require("packages/kits/moderation/tests/Fakes.luau")
local players = Fakes.players()                      -- BanAsync / UnbanAsync / GetBanHistoryAsync, recorded
local h = StudWork.test.harness({ modules = { Moderation }, isStudio = false,
	serverConfig = { Moderation = { admins = { 1 } } },  -- Admin off: the fallback staff list
	services = { Players = players, GroupService = Fakes.groupService(), TextChatService = Fakes.textChatService() } })
local mod, target = h:addPlayer({ userId = 1 }), h:addPlayer({ userId = 2 })
local ok, status = h:use(Moderation).ban(target, { by = mod, seconds = 3600, displayKey = "Moderation.ban.rules" })
-- ok == true, status == "banned"; players.bans[2].Duration == 3600
h:use(Moderation).kick(target, { by = "server", key = "Moderation.kick.rules" }) -- game code: by = "server"
```

## How the three fit together

```
           Admin  (depends on nothing; optional Economy for "grant", TextFilter for free text)
          ^     ^
          |     |   register panel actions, tabs, the audit sink (in init)
   Moderation   Reports
   optional:    optional: Admin, Moderation, TextFilter
   Admin,       Reports -> Moderation: Moderation.record for report audit entries,
   TextFilter   autoAction via Moderation.report
```

- **Admin is the base.** It never names Moderation or Reports. They find it as an optional
  dependency and, in their `init`, register into its extensions: Moderation registers the panel
  actions `ban`, `unban`, `kick`, `serverban`, `mute`, `unmute`, `warn` and `punish`, the
  `audit` tab and the audit sink; Reports registers the `reports` tab with its `claim` and
  `resolve` row actions. Module refs can't form a cycle, which is why the arrows point only
  toward Admin.
- **API or extension.** Each module has two surfaces. Its **API** (`ctx.deps[Admin]`,
  `StudWork.use(Admin)` in game code) is for calls at any time; its **extensions**
  (`ctx.depsExt[Admin]`) are registration hooks, called from your module's `init` (most raise an
  error after start). A function on one is not on the other: `ctx.deps[Admin].onStaffMove` is nil.
  For an optional dependency check `ctx.isEnabled(Admin)` first.

  | Module | API (`ctx.deps[Ref]`) | Extensions (`ctx.depsExt[Ref]`, in `init`) |
  |---|---|---|
  | Admin | `can`, `allow`, `rankOf`, `rankOfChecked`, `rankOfUserId`, `studioRoleOnly`, `limitsOf`, `roleOf`, `isStaff`, `permissions`, `onlineStaff`, signal `StaffJoined` | `registerPermission`, `registerAction`, `registerTab`, `registerDataView`, `onStaffMove`, `registerAuditSink`, `registerTextFilter` |
  | Moderation | `ban`, `unban`, `history`, `kick`, `serverBan`, `mute`, `unmute`, `isMuted`, `warn`, `punish`, `report`, `record`, `audit`, its signals | none |
  | Reports | `submit`, `queue`, `detail`, `claim`, `resolve`, `registerContext`, signals `Submitted`, `Resolved` | `registerContext` (the same function) |

  ```lua
  -- your anti-cheat module (dependsOn/optional lists Admin)
  function server.init(ctx)
  	if ctx.isEnabled(Admin) then
  		ctx.depsExt[Admin].onStaffMove(function(staff, target, kind) exempt(target) end)
  	end
  end
  ```
- **Each works alone.**

| Enabled | What you get | Fallbacks |
|---|---|---|
| Admin only | roles, permissions, the panel with Players, Announce, Data (teleport, spectate, announce, shutdown, grant currency, data view) and the `admin ...` console | no Moderation: panel actions are audited with `ctx.log.info` only |
| Moderation only | the full server API and the `moderation ...` console; no panel | permissions: Studio everyone, live only `ServerConfig.Moderation.admins`; no per-staff rate limits or role caps; staff-on-staff action refused when the target is in that list |
| Reports only | the report screen and the queue API (`queue`, `detail`, `claim`, `resolve`) through code or the `reports ...` console | permissions as above with `ServerConfig.Reports.admins`; claims and resolutions are logged with `ctx.log.info`; `autoAction` has nothing to call |
| Admin + Moderation | the panel gains Moderation's actions and the Audit tab; Admin's own actions are audited | |
| All three | the panel gains the Reports tab; claiming and resolving a report write audit entries (`Moderation.record`); `autoAction` can feed Moderation | |

**Without [TextFilter](textfilter.md)** every free-text field typed by staff is refused (presets
still work): a free ban message or kick message returns `"invalid"`, a staff `privateReason`
returns `"no_filter"`, a free announcement or other free panel text returns `"no_filter"`, and
report notes are dropped (the report itself is still filed). **With TextFilter**, its own config
still applies: `config.TextFilter.maxLength` defaults to **40** characters and longer input is
refused, so raise it (up to 200) for report notes and announcements; with
`TextFilter.respectContentSharing` a note from a player whose content-sharing policy is unknown or
denied is dropped too. A text the filter refuses or fails on is never stored or shown: staff get
`"invalid"` (Moderation) or `"failed"` (Admin), a note is dropped.

## Actors and permissions

Every mutating server function takes `opts.by`, the actor. **`by` is required**: `nil`, or any
value not in this table, raises an error that names the fix (pass `by = "server"` for game
code). Forgetting it can never grant power silently.

| `by` | Who | Checked how | Audited as |
|---|---|---|---|
| `"server"` | trusted game code (your modules) | never refused for permission or rank; its text is used as given | `byKind = "server"`, `by = 0` |
| `"console"` | a console command run without a player | as `"server"` | `byKind = "console"`, `by = 0` |
| a `Player` | a staff request (the panel, or your code acting for a player) | with Admin enabled: `Admin.allow(by, perm, action)` (permission plus per-staff limits), the rank rule and the role caps. Admin off: allowed only when `ctx.isStudio` or `by.UserId` is in `ServerConfig.<Module>.admins` | `byKind = "staff"`, `by = UserId` |
| `"system"` | automatic actions: the `Moderation.report` ladder, Reports' `autoAction` | only actions in `config.Moderation.auto.permissions` (default `warn`, `mute`, `kick`; never `ban` unless you add it); `history`, `audit` and the Reports queue calls refuse it (`"no_permission"`) | `byKind = "system"`, `by = 0` |

Refused actions are audited with `status = "refused"`, bounded so a loop can't flood the log: a
refused `"system"` action at most once per (target, source), and a refused staff request at most
once per (staff, action), per `config.Moderation.audit.refusedEverySeconds` (default 3600). Admin's
own refused built-in actions follow the same once per (staff, action) rule through the sink, per
`config.Admin.refusedAuditSeconds` (default 3600).

Rules that hold for every staff action:

- **No self-action, no upward action.** Staff can't act on themselves or on staff whose role
  `rank` is equal or higher (reason `"outranked"`). `"server"` and `"console"` are exempt. For a
  target in this server, the rank comes from `Admin.rankOfChecked`: while that player's role isn't
  resolved yet (a group lookup in flight, failed or over budget) the rank is **unknown**, never
  "not staff", and the action is refused with `"unknown_rank"` until the re-check succeeds. For a
  target that isn't in this server, the rank comes from `Admin.rankOfUserId`; if that lookup fails
  or is over the group budget, the action is refused with `"unknown_rank"` (fail closed). With
  Admin off, staff-on-staff action is refused when the target is in `ServerConfig.<Module>.admins`.
- **Studio: everyone is staff** with `config.Admin.studioRole` (default `"owner"`), the same rule
  as the framework's Studio admins (a `users` entry still wins, so you can test a lower role).
  Because everyone would then equal everyone, **the outranked check is skipped in Studio for a
  target whose role comes only from `studioRole`** (`Admin.studioRoleOnly(userId)`). Self-action
  is still refused in Studio, and a target with a `ServerConfig.Admin.users` entry is checked
  normally, so you can test the rank rule in Studio by listing both players in `users`; specs can
  also use `isStudio = false`. **Live:
  nobody is staff unless configured** in `ServerConfig.Admin.users` or `.groups` (or, with Admin
  off, `ServerConfig.<Module>.admins`).
- **Per-staff limits are counted once per action.** `Admin.allow` counts; `Admin.can` doesn't.
  Only an actual ban (`ban`, or a permanent one) counts toward `limits.bansPerHour`: an unban, a
  server ban or a ban-history read checks the `ban` permission without using the ban allowance.
  The module API (Moderation, Reports) calls `allow` for a staff actor. Admin's own request
  handling counts its **built-in** actions and a **registered tab's fetch** once (`allow`), and
  only checks `isStaff` plus `can` before a **registered** action or row action, whose `run` calls
  the module API with `by = staff` and is counted there.
- **Admin off.** A module can't read the framework's top-level `ServerConfig.admins` (it only sees
  `ctx.serverConfig`, its own part), so the fallback list is per module:
  `ServerConfig.Moderation.admins` and `ServerConfig.Reports.admins` (`{ number }`). A shared
  `ctx.framework.isAdmin(player)` is proposed in the pending file, not done. With Admin off there
  are **no per-staff limits** (`actionsPerMinute`, `bansPerHour`): Net limits only cover client
  requests, so a fallback admin acting through your own server code is not rate-limited by the
  kit. Keep Admin on for any game with more than a trusted handful of staff.
- **The console is server-only.** The framework's console runs a command without a player, so
  every kit console command acts as `by = "console"`: whoever can run server code (the Studio
  command bar, the developer console with edit access) can use it. A command given a player is
  checked like that player's staff request. The framework's own console commands (`economy
  grant`, `data dump`, ...) keep the framework's admin rule; no framework hook lets Admin's roles
  govern them (proposed, not done).

### Built-in permissions and role defaults

`ban`, `ban.permanent`, `kick`, `mute`, `warn`, `reports.read`, `reports.resolve`,
`reports.reporters`, `audit.read`, `teleport`, `spectate`, `data.read`, `data.grant`, `announce`,
`shutdown`. Games add their own with `registerPermission` (below). `"*"` means every built-in
permission plus every registered one.

| Permission | owner (400) | admin (300) | moderator (200) | helper (100) |
|---|---|---|---|---|
| `ban` (also `unban`, `serverBan`, ban history) | yes | yes | yes, at most 7 days (`maxBanSeconds = 604800`) | |
| `ban.permanent` | yes | yes | | |
| `kick`, `warn` | yes | yes | yes | yes |
| `mute` (also `unmute`) | yes | yes | yes, at most 1 day (`maxMuteSeconds = 86400`) | yes, at most 1 hour (`maxMuteSeconds = 3600`) |
| `reports.read` | yes | yes | yes | yes |
| `reports.reporters` | yes | yes | | |
| `reports.resolve` (claim and resolve) | yes | yes | yes | |
| `audit.read` | yes | yes | yes | |
| `teleport`, `spectate` | yes | yes | yes | |
| `data.read`, `announce` | yes | yes | | |
| `data.grant`, `shutdown` | yes | | | |

Role labels are `Admin.role.<role>` strings keys (English defaults for the four built-in roles; a
role you add gets its id as English unless you set the key). A registered permission's `roles` adds
it to those roles.

**Config merging:** `config.Admin.roles` in your `Balance.luau` is **merged over the defaults**,
role by role and field by field; it doesn't replace them. Overriding `moderator = { rank = 250 }`
keeps the moderator's permissions, `maxBanSeconds` and `maxMuteSeconds`; a `permissions` list you
give replaces that role's list whole (lists aren't merged). The four default roles always exist;
to take a default role out of use, give nobody that role (and, if you like, `permissions = {}`).

## Admin

### Config (`config.Admin`)

| Key | Default | Meaning |
|---|---|---|
| `flag` | none | a feature flag ([environments](environments.md)); off: nobody is staff (`can` is false and `allow` returns `"disabled"` for every player), the panel is removed, and every staff player's replicated `staff` key is cleared (checked every second) |
| `roles` | owner, admin, moderator, helper (table above) | `{ [role] = { rank, permissions, maxBanSeconds?, maxMuteSeconds?, label? } }`. `rank` is an integer 1..1000 (higher outranks lower); `permissions` lists permission names or `"*"`; `maxBanSeconds` and `maxMuteSeconds` cap a temporary ban or a mute for that role (`"too_long_for_role"`); `label` is a strings key for the panel. Merged over the defaults (above) |
| `studioRole` | `"owner"` | the role every player without a `users` entry has in Studio |
| `groupCacheSeconds` | `600` | a group lookup result is reused per user and group for this long |
| `groupLookupsPerMinute` | `60` | group lookups this server may make per minute; over budget, the role comes from the cache or is none, and the player is looked up again later |
| `groupRetrySeconds` | `60` | after a failed or over-budget lookup, the player's role is resolved again this much later (until it succeeds) |
| `limits.actionsPerMinute` | `30` | counted staff actions (`allow`) per staff member per minute, in this server (staff-abuse brake); over it: `"rate_limited"` |
| `limits.bansPerHour` | `20` | bans (an `allow` whose action is `ban` or `ban.permanent`) per staff member per hour, in this server; over it: `"rate_limited"`. Unbans, server bans and history reads don't count |
| `refusedAuditSeconds` | `3600` | a refused built-in panel action is audited at most once per (staff, action) per this many seconds |
| `panel.playerListMax` | `50` | rows per page in the panel's Players tab (1..200) |
| `grant.max` | `10000` | the largest amount one grant-currency action may give (1..`grant.max`) |
| `grant.currencies` | `{}` | the currencies the grant action offers; `{}` = Economy's primary currency only, and then only when it isn't a paid currency (a paid currency is offered only when you list it) |
| `announce.presetKeys` | `{ "Admin.announce.restart", "Admin.announce.event", "Admin.announce.rules" }` | the announcements staff may pick |
| `announce.freeText` | `true` | let staff type an announcement (filtered `"public"`; refused `"no_filter"` without a filter) |
| `announce.maxLength` | `200` | longest typed announcement (1..200; TextFilter's own `maxLength` applies too) |
| `shutdown.presetKeys` | `{ "Admin.shutdown.update", "Admin.shutdown.generic" }` | the kick messages the shutdown action may use |

Everything in `config.*` lives in `GameConfig`, which replicates to every client: treat it as
public. Secrets (who is staff, anti-cheat thresholds) go in `ServerConfig`.

### ServerConfig (`ServerConfig.Admin`, server-only)

| Key | Meaning |
|---|---|
| `users` | `{ [userId] = role }` |
| `groups` | `{ { groupId, roles = { { roleId?, minRank?, role } } } }`: a member whose role id matches `roleId`, or whose rank is at least `minRank`, gets `role` (each rule needs `roleId` or `minRank`; `role` must be in `config.Admin.roles`) |

**Role resolution** runs (in its own thread) when a player's data has loaded: the `users` map
first (no group lookup for a listed user); in Studio, `studioRole`; otherwise every group rule,
through `GroupService:GetRolesInGroupAsync(userId, groupId)` (in a `pcall`, cached per user and
group for `groupCacheSeconds`, within `groupLookupsPerMinute`). The highest-rank role that matches
wins. A failed lookup means "not staff" for permissions (or the cached role), is logged, and is
retried after `groupRetrySeconds`; for the rank rule and the Reports viewer rule that player's rank
is unknown until then (`rankOfChecked` answers nil), so they fail closed. Prefer `roleId`: Roblox says a role's rank "does not determine its position
in the role hierarchy. Use the stable `Id`", and only public roles are returned
([GroupService.GetRolesInGroupAsync](https://create.roblox.com/docs/reference/engine/classes/GroupService#GetRolesInGroupAsync)).
`Player:GetRankInGroup` and even `GetRankInGroupAsync` are deprecated in favour of it
([Player](https://create.roblox.com/docs/reference/engine/classes/Player)). A role is fixed for
the session apart from the re-check after a failure: a demotion in the group takes effect on the
player's next join, or remove the user id from `users` and use the `flag` for an emergency. A
server that fills quickly spends its group budget on the first joins, so a staff member late in
the join order may wait up to `groupRetrySeconds` for their role.

### API (server)

- `can(player, permission) -> boolean`: a pure permission check (no counting). **(contract)**
- `allow(staff: Player, permission, action?) -> (boolean, reason?)`: the permission check **plus**
  the per-staff limits: every allowed call counts toward `limits.actionsPerMinute`, and a call
  whose `action` (default: the permission) is `"ban"` or `"ban.permanent"` also toward
  `limits.bansPerHour` (counted per user id, so a rejoin doesn't reset them). Pass the action when
  it differs from the permission (Moderation passes `"unban"`, `"serverBan"`, `"history"` with the
  `ban` permission, so they don't use the ban allowance; `action` added in this release). Reasons `"no_permission"`, `"rate_limited"`, `"disabled"` (flag off).
  Moderation and Reports call `allow`, not `can`, for every staff actor. **(contract)**
- `rankOf(player) -> number`: the role rank of a player in this server (`0` = not staff, **or not
  resolved yet**: use `rankOfChecked` for any security decision). **(contract)**
- `rankOfChecked(player | userId) -> number?`: the rank only when it is **known without a group
  lookup**; `nil` = unknown (a lookup in flight, failed or over budget). A Player in this server:
  their resolved role (`0` = resolved, not staff). A user id: that player if in this server, else
  the `users` map, Studio's `studioRole`, or the group rules from a fresh cache entry only. Never
  yields and never spends `groupLookupsPerMinute`. Moderation's rank rule and the Reports viewer
  rule use it and fail closed on `nil`. (Added in this release.)
- `studioRoleOnly(userId) -> boolean`: true in Studio when the user's role comes only from
  `studioRole` (no `ServerConfig.Admin.users` entry); Admin and Moderation skip the outranked check
  for such a target (self-action is still refused). Never yields.
- `rankOfUserId(userId) -> (ok: boolean, rank: number)`: yields. An online, resolved player is
  answered at once; otherwise the `users` map, then (live) the group rules through GroupService
  with the same cache and budget; in Studio an unlisted user has the `studioRole` rank. `0` = not
  staff. `(false, 0)` when a lookup failed or the budget is spent; `(true, 0)` while the flag is
  off. Used for targets that aren't in this server. **(contract)**
- `limitsOf(staff: Player) -> { maxBanSeconds: number?, maxMuteSeconds: number? }`: the role's caps
  (frozen; `{}` for non-staff; owner and admin have none). Moderation reads it before a ban or a
  mute. **(contract)**
- `roleOf(player) -> string?`, `isStaff(player) -> boolean`. **(contract)**
- `permissions(player) -> { string }` (frozen, sorted; `"*"` expanded to every permission).
  **(contract)**
- `onlineStaff() -> { Player }` (server only; never replicated). **(contract)**
- signals: `StaffJoined(player, role)` (also fired again for every staff player when the flag
  turns back on). **(contract)**

The per-staff limits are counted per server, in memory: a staff member who hops servers gets a
fresh count (documented limit). Bans are also recorded in that staff member's own audit index
(`a/u/<staffUserId>`), so a ban spree across servers shows up in one place.

### Extensions (call in `init`) (contract)

Reached through `ctx.depsExt[Admin]` (list Admin in your module's `dependsOn` or `optional`), not
through the API: `ctx.deps[Admin].registerTab` is nil. All but `onStaffMove` raise an error when
called after start.

- `registerPermission(name, { roles: { string }? }?)`: `name` is 1..64 letters, digits, `_` or
  `.`; a built-in or already registered name errors.
- `registerAction(def: ActionDef)`: the ids `teleportTo`, `bring`, `spectate`, `stopSpectate`,
  `announce`, `shutdown`, `grant` and `dataView` are Admin's own; a duplicate id errors.
- `registerTab(def: TabDef)`: the tab ids `players`, `announce` and `data` are reserved; a
  duplicate id errors.
- `registerDataView(id, fn(target: Player) -> { [string]: number | boolean | string })`: one
  section of the Data view. A string value must be a declared strings key (shown localized);
  anything else is dropped, so player-typed text never reaches the panel unfiltered.
- `onStaffMove(fn(staff, target, kind: "to" | "bring"))`: runs before a teleport-to or bring, so a
  game's movement validator (anti-cheat) can exempt that move.
- `registerAuditSink(fn(entry: AuditRecord))`: where Admin sends its audit records (one sink).
  Moderation registers it; without a sink, Admin writes `ctx.log.info` only.
- `registerTextFilter(fn(author: Player, text) -> (ok, shown | reason))`: overrides the filter
  Admin runs free panel text through (announcements, an action's `freeText`, one filter). With
  TextFilter enabled Admin filters with it by itself (`"public"`); a registered filter wins. With
  neither, free text is refused (`"no_filter"`).

```
ActionDef = { id: string ([%w_]{1,32}), permission: string, labelKey: string (a strings key),
  target: "player" | "userId" | "none", presets: { string }? (strings keys the panel offers),
  durations: { number }? (seconds choices), freeText: boolean?,
  run: (staff: Player, targetUserId: number?, args: ActionArgs) -> (boolean, string?) }
ActionArgs = { preset: string?, duration: number?, text: string?, amount: number?, note: string? }
TabDef = { id, permission, labelKey,
  fetch: (staff, page: number) -> { rows: { { [string]: string | number | boolean } }, columns: { string } },
  rowActions: { RowAction }? }
RowAction = { id, permission, labelKey, presets: { string }? (e.g. resolutions), notes: { string }? (note keys),
  run: (staff, rowId: string, args: ActionArgs) -> (boolean, string?) }
AuditRecord = { action, by: number (0 = server/console), byKind, target: number?, reasonKey: string?,
  note: string?, seconds: number?, status: "ok" | "pending" | "failed" | "refused", amount: number?, currency: string? }
```

What Admin checks before calling `run` (a request from the client is a request, not a fact):

1. The sender is staff (else dropped, no reply).
2. The permission: `allow` for built-ins (counted), `can` for registered actions and row actions
   (the module API they call counts).
3. The arguments: `preset` must be one of `presets`; `duration` one of `durations`; `text` only when
   `freeText` and at most 200 bytes (an announcement: `announce.maxLength`); an amount (the grant
   action) an integer 1..`grant.max`. A row action's `rowId` must be the `id` of a row the server
   sent that staff member for that tab; its choices must be one of the row action's `presets` and
   `notes`.
4. The target: `"player"` must be in this server (`"not_found"`), `"userId"` any user id; then the
   rank rule (`"outranked"`, `"unknown_rank"`; in Studio skipped only for a `studioRole`-only
   target, self-action still refused).
5. Free text through the text filter; only the broadcast string reaches `run` as `args.text`.

`run`'s second value becomes the reply: a reason or status `x` is sent as `Admin.result.x`; a
dotted strings key (at most 64 characters, e.g. `Moderation.result.banned`) is sent as is. A `run`
that errors replies `"failed"`.

### Built-in actions

| Action id | Permission | Target | What it does |
|---|---|---|---|
| `teleportTo`, `bring` | `teleport` | player | moves the staff to the target or the target to the staff (next to them); `onStaffMove` hooks run first; audited `"teleport"` |
| `spectate`, `stopSpectate` | `spectate` | player, none | sends the target's user id (or nil) to that staff's client only (`Spectate`) and sets their `ReplicationFocus`; `spectate` is audited. When the target leaves, every staff member spectating them gets `Spectate(nil)` and their `ReplicationFocus` cleared |
| `announce` | `announce` | none | a preset from `announce.presetKeys`, or (with `announce.freeText`) typed text filtered `"public"`; sent to everyone in this server; audited |
| `shutdown` | `shutdown` | none | kicks everyone in this server with a preset from `shutdown.presetKeys` (localized per player) and kicks every later join; audited. Moderation flushes the audit and pending writes when the server closes (`audit.shutdownSeconds`) |
| `grant` | `data.grant` | player | `Economy.grant(target, amount, "admin:<staffUserId>", currency)`; the amount 1..`grant.max`, the currency from `grant.currencies` (or the primary currency). Only offered with Economy enabled and a currency to give; audited with amount and currency |
| `dataView` | `data.read` | player | the Data view: framework facts (`firstJoin`, `lastSeen`, `sessions`), every registered data view, and Economy balances when Economy is enabled; sent as `Rows("data", ...)` |

### Network

Every client request is a §9 module **action** (declared in the server part, scoped to the
module, rate-limited by the framework's Net, reachable in specs with `h:action`); Admin's
`net.blink` (RemoteScope `STUDWORK_ADMIN`) carries the wire types and the server -> client events.

| Direction | Name | Who |
|---|---|---|
| client -> server (actions) | `run(actionId, targetUserId?, preset?, duration?, text?)` (1 per s, burst 5), `fetch(tabId, page)` (1 per s, burst 4), `panelOpen(0)` (one per 5 s, burst 2; Blink needs a data field) | any client may send; the server checks staff first |
| server -> one staff | `Rows(tabId, page, json)`, `RunResult(ok, key)`, `Spectate(userId?)` | only that staff player |
| server -> all | `Announce(payload)` | everyone in this server |

Wire encodings (the `net.blink` shape is fixed, so some arguments share a slot):

- **Row action:** `run("<tabId>/<rowActionId>", nil, rowId, nil, "<preset>" | "<preset>|<note>")`;
  `rowId` rides in the `preset` slot, the choices in `text`.
- **Amount** (the grant action): in the `duration` slot; the currency in `preset`.
- **Announce payload:** `"k|<strings key>"` (a preset, localized by each client) or
  `"t|<filtered text>"`, at most 400 bytes.
- **Rows:** JSON `{ columns, rows, target? }`; at most 100 rows and 12 columns, a string cell at
  most 200 characters, the JSON at most 30000 bytes (rows are dropped from the end to fit). Row
  ids are sent as strings.
- **RunResult key:** `Admin.result.<reason or status>` or a module's dotted key (see above).

A request from a non-staff player is **dropped with no reply**, identical to an unknown action,
and counted only in a server log line, so a probing client learns nothing.

### Replication

Only for staff: `ctx.replicate.set(staff, "staff", { role, label, rank, permissions, actions, tabs,
playerListMax })`, where `actions` are the actions that staff may use, `{ id, labelKey, target,
presets, durations, freeText, permission, amount? }` (`amount = { min, max }` for grant), and
`tabs` the tabs they may open with their permitted `rowActions` (including `presets` and
`notes`). **(contract)** A non-staff player has no `staff` key at all; it is cleared when the role
is lost or the flag goes off. Never `setAll`; the staff list is never replicated.

### Client part and the panel

The panel's React code lives in the **server** part (`Admin/server/Panel/`) and is cloned into a
`ScreenGui` named `StudWorkAdminPanel` (`ResetOnSpawn = false`) in the staff player's `PlayerGui`
only, so it replicates to that player only: a non-staff client never receives the panel's code. It
is removed when the role is lost or the flag goes off; `panelOpen` re-sends the `staff` state and
re-delivers a missing panel. (Spec seam: delivery calls `player:FindFirstChild("PlayerGui")`;
specs give mock players a fake `PlayerGui` and may replace `placePanel`.) The client part is tiny:
`StudWork.use(Admin).isStaff()`, `.permissions()`, `.role()`, `.panel()` (opens the delivered panel
if present, otherwise does nothing); it mounts the delivered panel, follows `Spectate` with the
camera and shows `Announce` as a notification.

Tabs: **Players** (this server's players, `panel.playerListMax` per page, with quick actions and
preset, duration, amount and text pickers, two-tap confirm), **Reports** (when Reports registers
it), **Audit** (when Moderation registers it), **Announce**, **Data**. Mobile first: laid out for
667x375 landscape, every touch target at least 44 px, theme tokens only (no colours in code),
every label a `UI.text` key (`Admin.*`, English defaults in the module's `strings`; string cells
from a tab are shown as keys when they are keys). The panel uses no tweens or animations at all
(its own flat buttons), so it respects reduced motion by construction.

### Console

`admin staff` (staff in this server and their roles), `admin role <userId>`, `admin announce
<presetKey>`, `admin shutdown <presetKey>`, `admin grant <amount> <currency> <userId>` (player in
this server), `admin tp <userId to move> <userId to move to>`, `admin data <userId>`. Run as
`"console"` and audited `byKind = "console"`.

### Save data

None. Roles come from `ServerConfig` and group lookups each session.

## Moderation

### Config (`config.Moderation`)

| Key | Default | Meaning |
|---|---|---|
| `flag` | none | off: every action returns `(false, "disabled")` and `report` returns false; joins are unaffected (Roblox's own bans still apply), and pending ban retries keep running |
| `ban.excludeAltAccounts` | `false` | passed to `BanAsync` as `ExcludeAltAccounts`; `false` means the ban also covers suspected alt accounts |
| `ban.applyDeviceBlock` | `false` | passed as `ApplyDeviceBlock` |
| `ban.displayKeys` | `{ "Moderation.ban.rules", "Moderation.ban.cheating", "Moderation.ban.harassment" }` | the ban messages staff may pick (strings keys) |
| `ban.allowFreeDisplay` | `false` | let staff type the ban message; it must pass TextFilter `"public"` |
| `ban.maxDisplayLength` | `200` | longest free ban message, in characters (1..400) |
| `ban.defaultDisplayKey` | `"Moderation.ban.rules"` | used when the caller gives no key and no offence |
| `kick.presetKeys` | `{ "Moderation.kick.generic", "Moderation.kick.rules" }` | kick messages staff may pick; the first is the default |
| `kick.allowFreeText` | `false` | let a caller give kick text (a staff member's text must pass TextFilter `"public"`) |
| `kick.maxLength` | `500` | kick messages are cut to this many bytes on a UTF-8 boundary (1..500) |
| `serverBan.defaultSeconds` | `3600` | a this-server-only ban's length when none is given |
| `serverBan.maxSeconds` | `86400` | longest server ban (longer: `"invalid"`) |
| `mute.defaultSeconds` | `600` | mute length when none is given |
| `mute.maxSeconds` | `604800` | longest mute (7 days; longer: `"invalid"`); a role's `maxMuteSeconds` caps lower |
| `mute.textChat` | `true` | a mute sets `TextSource.CanSend = false` |
| `mute.voice` | `false` | a mute also silences voice (`AudioDeviceInput.AccessType = Allow` with an empty list); verify live |
| `mute.presetKeys` | `{ "Moderation.mute.generic", "Moderation.mute.spam", "Moderation.mute.language" }` | mute reasons; the first is the default |
| `warn.presetKeys` | `{ "Moderation.warn.rules", "Moderation.warn.language", "Moderation.warn.cheating" }` | warnings staff may pick |
| `ladders` | `{ default = { { action = "warn" }, { action = "mute", seconds = 600 }, { action = "kick" }, { action = "ban", seconds = 86400 } } }` | escalation steps; `punish` takes the next one. A `ban` step without `seconds` is permanent. A step may carry `key`, the message it uses (one of that action's presets: `warn.presetKeys`, `mute.presetKeys`, `kick.presetKeys`, or for a ban `ban.displayKeys` or an offence's `displayKey`; checked at boot). Without one: a warn uses the offence's `warnKey`, then the first of `warn.presetKeys`; a mute or kick the first of its presets; a ban the offence's `displayKey`, then `ban.defaultDisplayKey` |
| `offenses` | `cheating`, `harassment`, `rules` (each `ladder = "default"`, `displayKey = "Moderation.ban.<id>"`) | `{ [offense] = { ladder, displayKey, warnKey? } }`: which ladder an offence climbs, the ban message it uses and (optional) the warning a `warn` step sends for it (one of `warn.presetKeys`, checked at boot); labels `Moderation.offense.<id>` |
| `strikes.decayDays` | `30` | a strike older than this no longer counts |
| `strikes.max` | `20` | strikes kept per player |
| `auto.enabled` | `true` | `report` may act on its own |
| `auto.permissions` | `{ "warn", "mute", "kick" }` | the only actions `by = "system"` may take (no `ban` by default) |
| `auto.sources` | `{}` | `{ [source] = { threshold, windowSeconds, offense } }`: when the severity a player collects from one source within `windowSeconds` reaches `threshold`, `punish` runs for `offense`. Public (replicated with `GameConfig`): prefer `ServerConfig.Moderation.autoSources` |
| `audit.retentionDays` | `30` | audit days are deleted after this (1..90); older entries are never returned, and `a/u/<userId>` drops them on its next write |
| `audit.perTargetMax` | `30` | entries kept in one player's index `a/u/<userId>` |
| `audit.flushSeconds` | `15` | how often buffered entries are written (only when there are any) |
| `audit.chunkSize` | `100` | entries per audit chunk key before a new chunk starts |
| `audit.bufferMax` | `500` | entries buffered in memory; past it the oldest are dropped (and counted in the log) |
| `audit.readSecondsPerStaff` | `5` | one audit read per staff member per this many seconds (`"rate_limited"`) |
| `audit.readCacheSeconds` | `30` | an audit read result is reused for this long (time only: new entries don't clear it; this server's own entries are added from memory) |
| `audit.chunksPerRead` | `4` | chunk keys one day read touches (plus the day directory), newest first; older chunks on the next page |
| `audit.privateReasonMax` | `300` | characters of `privateReason` kept in the audit (the full text goes only to `BanAsync`) |
| `audit.detailsMaxBytes` | `200` | `report` details kept in the audit entry, encoded |
| `audit.refusedEverySeconds` | `3600` | a refused action is audited at most once per (target, source) or (staff, action) per this |
| `audit.shutdownSeconds` | `5` | the time budget for pending writes and the last audit flush at shutdown |
| `retry.base`, `retry.factor`, `retry.max` | `5`, `2`, `300` | backoff (seconds) for `BanAsync`, `UnbanAsync` and store writes; `max` is also the pending lease length |
| `retry.maxAttempts` | `20` | after this many attempts a pending ban or unban is dropped and audited `"failed"` |
| `crossServer.kickMaxAgeSeconds` | `600` | a cross-server kick older than this when it arrives is dropped (audited `"failed"`, note `Moderation.note.staleKick`) |
| `crossServer.perTargetPerHour` | `5` | cross-server messages one server may send about one target per hour (`"rate_limited"`) |
| `pending.indexExpiryDays` | `7` | expiry of an entry in the `pending` sorted map (renewed while work remains) |
| `pending.pollSeconds` | `60` | how often each server scans the `pending` index |
| `unknownRecheckSeconds` | `30` | with `onUnknownStatus = "admit"`, how often a let-in player's pending-ban status is read again |
| `panel.banDurations` | `{ 3600, 86400, 604800, -1 }` | ban lengths the panel offers (`-1` = permanent) |
| `panel.muteDurations` | `{ 300, 600, 3600, 86400 }` | mute lengths the panel offers |
| `panel.serverBanDurations` | `{ 600, 3600, 86400 }` | server-ban lengths the panel offers |
| `panel.auditPageSize` | `20` | rows per Audit tab page, and `audit()`'s default `limit` (1..100) |
| `panel.auditMaxRows` | `200` | the most entries one audit read returns (1..1000) |
| `history.cacheSeconds` | `60` | a `history` result is reused for this long |
| `onUnknownStatus` | `"admit"` | when the pending-ban index can't be read at a join: `"admit"` (let in, re-check every `unknownRecheckSeconds`) or `"hold"` (kick with `Moderation.kick.hold`) |

A ladder's steps have different fields (`{ action, key }`, `{ action, seconds }`, `{ action }`), and
luau-lsp in a `--!strict` `Balance.luau` refuses a table literal that mixes them ("Table type ... not
compatible"). Cast the list:

```lua
-- Balance.luau (--!strict)
Moderation = {
	warn = { presetKeys = { "Moderation.warn.rules", "game.warn.teleport" } },
	ladders = {
		anticheat = {
			{ action = "warn", key = "game.warn.teleport" },
			{ action = "mute", seconds = 300 },
			{ action = "kick" },
		} :: { any }, -- mixed step shapes: one cast per ladder
	},
	offenses = { teleport = { ladder = "anticheat", displayKey = "Moderation.ban.cheating" } },
},
```

### ServerConfig (`ServerConfig.Moderation`)

| Key | Meaning |
|---|---|
| `admins` | `{ number }?`: user ids allowed to act while Admin is off (see Actors) |
| `autoSources` | `{ [source] = { threshold, windowSeconds, offense } }?`: merged over `config.Moderation.auto.sources` (this one wins). Server-only, so an exploiter can't read your anti-cheat thresholds; **recommended** place for them |

### Strings

Every message a player sees is a `Moderation.*` key with an English default in the module's
`strings`; games reword them in `GameConfig.strings`. Kick, mute and warn presets are localized for
the target with `ctx.text.format(target, key)`. `Moderation.ban.appeal` is the appeal line
appended to every ban message (default "To appeal, contact the game's support."): set it to your
real appeal path, because Roblox asks every game that bans to offer one (below).
`Moderation.history.custom` stands in for a ban reason in `history` that isn't one of your
presets. The panel shows results as `Moderation.result.<status or reason>` keys; audit notes are
`Moderation.note.*` keys (`staleKick`, `sendFailed`, `retriesExhausted`, `takeover`, `sent`,
`pendingUnsaved`).

### API (server)

Actions that call Roblox **yield**; call them from an action handler or a spawned thread, never
inside `ctx.tx`. All take a required `opts.by` (see Actors) and return `(ok, statusOrReason)`.

- `ban(target: Player | number, opts) -> (ok, status)` **(contract)**, `opts = { by, seconds?,
  displayKey?, displayText?, privateReason?, offense? }`. **`seconds` nil or `-1` is permanent**
  (needs `ban.permanent`); otherwise an integer > 0, and more than the role's `maxBanSeconds` is
  refused (`"too_long_for_role"`). `displayKey` defaults to the offence's key, then
  `ban.defaultDisplayKey`, and must be one of `ban.displayKeys` or an offence's key. Calls
  `Players:BanAsync` with `ApplyToUniverse = true`, the configured alt and device options,
  `DisplayReason` = the English string of the display key (`ctx.text.english`) or the filtered
  free text, plus the appeal line, cut to 400 characters on a UTF-8 boundary, and `PrivateReason`
  = the raw `privateReason` (it goes only there; the audit keeps the filtered text, cut to
  `audit.privateReasonMax`). The duration and reason are validated **before** the call. Statuses:
  `"banned"`, or `"pending"` when `BanAsync` failed **transiently** (the error contains
  `"failure for UserId"`, or a timeout or HTTP word): the player is kicked here if present, the ban
  is saved as a pending entry and retried with backoff (audited `"pending"`, then `"ok"` or
  `"failed"`); play continues for everyone else. Any other error is `(false, "failed")`, audited,
  and never pending.
- `unban(userId, { by, privateReason? }) -> (ok, status)` **(contract)**: needs `ban` and passes
  the rank rule. `UnbanAsync` with `ApplyToUniverse = true` (a universe unban doesn't lift a
  place-level ban, so the kit only ever bans universe-wide); `"unbanned"` or `"pending"`, retried
  like a ban. It also lifts a server ban here. An unban **replaces** a pending ban for that user
  in the same write (and a ban replaces a pending unban), so a ban that failed during an outage
  and was then undone never comes back.
- `history(userId, { by }) -> (ok, { HistoryEntry } | reason)` **(contract)**: a plain list from
  the first page of `GetBanHistoryAsync`, cached `history.cacheSeconds`; a staff actor needs `ban`
  or `audit.read`, `"system"` is refused. `HistoryEntry = { ban: boolean, reasonKey: string,
  startTime: string, seconds: number, placeId: number }`: a Roblox reason is shown as its preset
  key only when it equals the English text of one of your ban presets (with or without the appeal
  line); otherwise `Moderation.history.custom` (bans made from Open Cloud or the Creator Hub carry
  unfiltered text); an unban entry is `Moderation.history.unban`. In Studio: `(false,
  "unavailable")` (production only); a failed call `(false, "failed")`.
- `kick(target, { by, key?, text? }) -> (ok, status)` **(contract)**: `key` defaults to the first of
  `kick.presetKeys` and must be one of them. `text` needs `kick.allowFreeText` (else `"invalid"`);
  a staff member's text passes TextFilter `"public"` on this server before anything is sent.
  `Player:Kick` here (`"done"`), or a cross-server message when the target is elsewhere
  (`"sent"`). The message is cut to `kick.maxLength` bytes on a UTF-8 boundary.
- `serverBan(target, { by, seconds? }) -> (ok, status)` **(contract)**: needs `ban`; `seconds` up to
  `serverBan.maxSeconds`. This server only, in memory: kicks and refuses a rejoin to this server
  until it expires (`"done"`).
- `mute(target, { by, seconds?, key? }) -> (ok, status)`, `unmute(target, { by }) -> (ok, status)`
  (needs `mute`), `isMuted(player) -> (boolean, untilTs?)` **(contract)**. The mute is saved in the
  target's section, so it follows the player to every server and survives a rejoin. `key` is one of
  `mute.presetKeys` (default the first). `"done"` or `"sent"`; longer than `mute.maxSeconds`:
  `"invalid"`; longer than the role's `maxMuteSeconds`: `"too_long_for_role"`.
- `warn(target, { by, key }) -> (ok, status)` **(contract)**: `key` (required) one of
  `warn.presetKeys`; the player sees the localized preset (the `Notice` event); counted in
  `warnings`. `"done"` or `"sent"`.
- `punish(target: Player | number, offense, { by }) -> (ok, stepOrReason, status?)` **(contract)**:
  the next ladder step for that offence from the target's non-decayed strikes (clamped to the last
  step); for a target in this server, `step` is `"warn"`, `"mute"`, `"kick"` or `"ban"` and
  `status` the inner action's status. For an absent target the step is chosen on delivery, so it
  returns `(true, "sent", "sent")`; a staff sender must then hold the permission of every step of
  that offence's ladder, and the sender's role caps (`maxBanSeconds`, `maxMuteSeconds`) travel with
  the message: the target's server refuses a step longer than them (`"too_long_for_role"`,
  audited `"refused"`). When `Admin.limitsOf` errors the caps are unknown and nothing is sent:
  `(false, "failed")`, audited `"refused"`. Refused: `(false, reason)`. A strike is recorded only when the step was
  applied (`"done"`, `"sent"`, `"banned"`, `"pending"`), never for a refused or failed step.
- `report(target: Player | number, source, severity, details?) -> boolean` **(contract)**: the
  automatic hook for your anti-cheat or chat heuristics. Never yields (the punish is spawned).
  Returns true when the report was counted (auto on, flag on, a known source, a severity > 0, a
  valid target), false otherwise. Sums severity per (target, source) within the source's window;
  crossing `threshold` runs `punish` with `by = "system"` and starts the window over. Works for
  targets that already left (by user id). `details` are encoded to at most
  `audit.detailsMaxBytes`, server only, kept in the audit entry.
- `audit({ by, target?, day?, limit?, page? }) -> (ok, { AuditEntry } | reason, more?)`
  **(contract)**: a staff actor needs `audit.read`, `"system"` is refused; `limit` defaults to
  `panel.auditPageSize`, at most `panel.auditMaxRows`; at most one read per staff member per
  `audit.readSecondsPerStaff` (`"rate_limited"`), results cached `audit.readCacheSeconds`. With a
  `target`, only that player's index `a/u/<userId>` is read. Without one, a day read touches the
  day directory plus at most `audit.chunksPerRead` chunk keys, newest first; `page` (default 1)
  picks the next `chunksPerRead` chunks and the third value `more` is true when older chunks exist
  (`page` and `more` added in this release). Entries older than `audit.retentionDays` are never
  returned.
- `record(entry, { by }) -> (ok, reason?)` **(contract)**: lets other kit modules write an audit
  entry (Reports' claim and resolve). Server only; no permission check (the caller decides).
  `entry = { action, target?, reasonKey?, note?, seconds?, status? }`; `action` must be one of
  `"report_resolved"`, `"report_claimed"`, `"grant"`, `"announce"`, `"teleport"`, `"spectate"`,
  `"shutdown"`, `"custom"`; keys at most 64 characters, `status` one of the audit statuses;
  anything else is `(false, "invalid")`. (The `module.luau` type says `-> boolean`; the second
  value is extra.)

Success statuses: `ban` `"banned"` or `"pending"`; `unban` `"unbanned"` or `"pending"`; `kick`,
`mute`, `unmute`, `warn`, `serverBan` `"done"` (applied in this server) or `"sent"` (queued through
`ctx.data.messages` for another server or the next load; `serverBan` is always `"done"`). `"sent"`
is returned at once: the send runs in its own thread, and a send that finally fails is audited
`"failed"` (note `Moderation.note.sendFailed`).

Reasons: `"no_permission"`, `"outranked"`, `"unknown_rank"` (a target's rank couldn't be looked
up), `"invalid"` (bad argument, unknown key, bad duration, free text not allowed by config,
staff free text without TextFilter or refused by it), `"no_filter"` (a staff `privateReason`
without TextFilter), `"disabled"` (flag off), `"rate_limited"` (Admin's per-staff limits, audit
reads, or more than `crossServer.perTargetPerHour` cross-server messages to one target from this
server), `"too_long_for_role"`, `"failed"` (a non-transient `BanAsync`/`UnbanAsync` error, or a
failed `history` call), `"unavailable"` (history in Studio).

Signals **(contract)**: `Actioned(entry: AuditEntry)` (every written entry), `Muted(player,
untilTs?)` (nil = unmuted), `Banned(userId, seconds)` (also when a pending ban finally succeeds).

Extensions: none. When Admin is enabled, Moderation calls Admin's `registerAction` (eight actions:
`ban` with `panel.banDurations`, `unban`, `kick`, `serverban` (target in this server,
`panel.serverBanDurations`), `mute` with `panel.muteDurations`, `unmute`, `warn`, `punish` with the
offences as presets), `registerTab` (`audit`, needs `audit.read`, columns when, by, player, action,
reason, status) and `registerAuditSink` in `init`.

At start Moderation reads `Players.BanningEnabled` (in a `pcall`) and warns once in the log if it
is false: Roblox only lets you turn it on in Studio's Players properties, and with it off every
ban fails.

### Console

`moderation ban <userId> [seconds|-1] [displayKey]`, `unban <userId>`, `kick <userId> [key]`,
`serverban <userId> [seconds]`, `mute <userId> [seconds] [key]`, `unmute <userId>`, `warn <userId>
<key>`, `punish <userId> <offense>`, `history <userId>`, `audit [userId]`. The console is
server-only (no player reaches it live), so every command acts as `by = "console"`, trusted, and is
audited as such.

### Network and client

`net.blink` (RemoteScope `STUDWORK_MODERATION`): `Notice(key: string(1..64), argsJson:
string(0..400))`, server -> that player only (no client -> server events). The client shows the
localized warning or mute notice in a `"ModerationNotice"` screen (a modal; registered unless the
game registers its own, props `key`, `args`, `onClose`). Client API:
`StudWork.use(Moderation).isMuted() -> (boolean, untilTs?)` from the player's own replicated
`extra.muted = untilTs` **(contract)**, and `.onNotice(fn(key, args)) -> Connection` for a game's
own notice UI. Nothing about other players is sent.

### Save data

Section `moderation`, version 1: `{ mute = { untilTs = 0, reasonKey = "" }, strikes = { { offense,
at, step } }, warnings = 0, seen = {} }`. Not replicated (only `extra.muted`). `seen` holds the ids
of processed cross-server messages (at most 50) so a message delivered twice is applied once.

### Shared store keys

`ctx.data.shared` has only `update`: a read is an update whose function returns `old` (a full
write), **never `nil`** (which deletes the key). So everything that is listed or polled lives in a
sorted map (`ctx.data.sortedMap`, whose `get` and `range` are reads), and the shared keys are small
and per user or per chunk.

| Store | Key | Holds |
|---|---|---|
| `ctx.data.shared` | `a/<day>/<job8>/<seq>` | one audit chunk: at most `audit.chunkSize` entries from one server (`job8` = the first 8 characters of the JobId, or `"studio"`); then `seq + 1` |
| `ctx.data.shared` | `a/<day>/d` | that day's directory: one append per **new** chunk |
| `ctx.data.shared` | `a/u/<userId>` | the last `audit.perTargetMax` entries about (or, for bans, by) one player |
| `ctx.data.shared` | `bans/p/<userId>` | the pending ban or unban for one user: `{ kind = "ban" \| "unban", seq, seconds, displayKey, privateReason, by, at, attempts, owner, leaseUntil }` |
| sorted map `pending` | key `userId` | `{ kind, seq, owner, leaseUntil }`: the discovery index of pending entries, expiry `pending.indexExpiryDays`, renewed |
| `ctx.data.shared` | `a/s` | the retention sweep's marker `{ day }`: every day up to it is swept |
| sorted map `pending` | key `sweep` | the lease for the audit retention sweep |

### Pending bans and unbans

- **Writing.** A transient `BanAsync`/`UnbanAsync` failure writes `bans/p/<userId>` and the
  `pending` index entry. A new ban or unban for the same user replaces the entry in the same
  update with a higher `seq`; a retry applies only the latest `seq`.
- **Lease.** The entry holds `owner = JobId` and `leaseUntil = now + retry.max`, renewed on each
  attempt. Only the lease holder retries; another server takes over only after the lease
  expired (audited with note `Moderation.note.takeover`), so an incident never makes every server
  call `BanAsync` at once.
- **Finding work.** Every server `range`s the `pending` index every `pending.pollSeconds` (reads
  only).
- **Joins.** A joining player costs one `get` on the index for that user. A pending `"ban"` kicks
  them (re-banned locally, with the ban message). If the read fails, `onUnknownStatus` decides.
- **Store down too.** When `BanAsync` fails transiently **and** both the per-user key and the
  index write fail, the status is still `"pending"`: the entry is kept in this server's memory
  only (it still refuses that player here and is saved on a later attempt or at shutdown) and the
  audit entry carries the note `Moderation.note.pendingUnsaved`. Only this server retries it.
- **Giving up.** After `retry.maxAttempts` the entry is removed and audited `"failed"` (note
  `Moderation.note.retriesExhausted`).
- **Shutdown.** Pending writes and the audit flush get `audit.shutdownSeconds` in total; a pending
  ban stays in the index so another server retries it.

### Text chat and voice mute

A text mute sets `CanSend = false` on every `TextSource` whose `UserId` is muted, re-applied when a
new source appears (`DescendantAdded`) and restored on unmute or expiry (only the sources the kit
changed). A `TextSource` exists per channel, and with `CanSend` false the user "can only read
messages" ([TextSource](https://create.roblox.com/docs/reference/engine/classes/TextSource)). The
voice mute uses `AudioDeviceInput` access lists, which "should only be assigned from the server"
([AudioDeviceInput](https://create.roblox.com/docs/reference/engine/classes/AudioDeviceInput)).

## Reports

### Config (`config.Reports`)

| Key | Default | Meaning |
|---|---|---|
| `flag` | none | off: `submit` returns `"disabled"` (the reporter sees `Reports.disabled`) and `open()` does nothing; staff can still read, claim and resolve the queue |
| `categories` | `{ "cheating", "harassment", "inappropriate", "scam", "other" }` | the choices; labels are `Reports.category.<id>` keys |
| `note.enabled` | `true` | the optional note box |
| `note.maxLength` | `120` | longest note in characters (0..200; a longer one makes the submit `"invalid"`). Filtered `"public"` through TextFilter at submit and only the filtered text kept; without TextFilter, on a filter refusal or failure (including TextFilter's own `maxLength`, default 40, and its content-sharing policy) the note is dropped and the report still filed |
| `limits.perReporterPerHour` | `5` | reports one player can file per hour |
| `limits.perReporterPerDay` | `15` | per day (at most `limits.sentMax`) |
| `limits.perPairPerDay` | `1` | reports of the same target by the same reporter per day |
| `limits.perTargetPerDay` | `30` | merged reports one target can collect per day |
| `limits.sentMax` | `50` | entries kept in the reporter's own `sent` list (the durable record the reporter limits count) |
| `recentSeconds` | `600` | players who left this server within this time can still be reported |
| `contextMaxBytes` | `600` | size cap of the context registered functions add |
| `queue.maxOpen` | `300` | open reports kept in the queue; when full, a new report evicts the lowest-priority one (fewest distinct reporters, then oldest), and the newcomer itself is dropped if it is the lowest |
| `queue.indexExpiryDays` | `7` | expiry of a `queue` index entry, renewed on every write to that report. A report untouched for longer is closed: the next read deletes its key (reporter ids and notes with it) and the next report starts over. Reporter ids older than this are dropped on every write |
| `autoAction.enabled` | `false` | feed reports into `Moderation.report` |
| `autoAction.distinctReporters` | `5` | distinct reporters within the window that trigger it |
| `autoAction.windowSeconds` | `1800` | the window (and at most one trigger per window per target) |
| `autoAction.source`, `autoAction.severity` | `"reports"`, `1` | the `report(target, source, severity)` call made (a Player, or a user id for a target who left); still bounded by `Moderation.auto.permissions`, and the source must exist in Moderation's sources |
| `blockPrompt` | `true` | after a report of a player in this server, offer `SetCore("PromptBlockPlayer", target)` |

Over any limit the reporter sees the same "thanks" as for an accepted report: nothing in the
reply tells a spammer which limit they hit or that the report was dropped. Limits are counted
server-side (`reports stats` on the console). The limit values are in `GameConfig` and so
readable by clients; the secrecy is about the outcome of a single report, not the numbers. Known
limit: an accepted report waits for the note filter and two store writes before the toast, a
capped one doesn't, so a client timing the toast can tell them apart (see the pending file).

### ServerConfig (`ServerConfig.Reports`)

`admins: { number }?`: user ids who may read and resolve reports while Admin is off.

### API (server)

- `submit(reporter: Player, targetUserId, category, note?) -> (ok, reason?)` **(contract)**: yields
  (note filtering, store write). The target must be in this server or have left within
  `recentSeconds`, and not the reporter. A second report of the same target merges into the open
  one (`count`, `distinct` and `reporters` grow; at most 100 reporters and 20 notes kept). Reasons
  (server-side only; the action replies "thanks" regardless): `"disabled"`, `"invalid"`,
  `"not_reportable"`, `"not_loaded"`, `"reporter_hour"`, `"reporter_day"`, `"pair"`,
  `"target_day"`, `"failed"`.
- `queue({ by, status?, limit? }) -> (ok, { ReportSummary } | reason)` **(contract)**: needs
  `reports.read`. Reads the `queue` index with `range` (no store write), highest priority first;
  `status` `"open"` or `"claimed"`; `limit` default 50, at most `max(200, queue.maxOpen)`; the
  index is paged through (200 entries a `range`), so every open report is reachable. Never
  contains reports whose target is the viewer or a staff member of equal or higher rank (with
  Admin off: targets in the admins list). The target's rank is its **current** rank as Admin knows
  it without a group lookup (`Admin.rankOfChecked`); a target whose rank is unknown is **hidden**
  (never a rank remembered from when the report was filed: the player may have been promoted
  since), so listing the queue never spends Admin's `groupLookupsPerMinute`. With
  `ServerConfig.Admin.groups` set, the rank of a player who left is known only while Admin's group
  cache holds it (`groupCacheSeconds`, default 600): after that, reports about them are hidden from
  staff until the player is in a server again (or another lookup caches the rank); trusted code
  (`by = "server"`, the console) still sees every report. Raise `groupCacheSeconds` if your staff
  work the queue long after the reported players leave. With only the `users` map every rank is
  known. `ReportSummary = { id, at, lastAt, target, targetName, category, count, distinct,
  status, claimedBy? }` (exactly these fields: no reporter ids, no notes, no ranks).
- `detail(reportId, { by }) -> (ok, Report | reason)` **(contract)**: needs `reports.read`; the
  only path to a report's notes and reporter ids (one store read). Hidden or missing:
  `"not_found"`. A queue entry whose report key is gone (a resolve that raced a submit in another
  server) is removed from the index when staff open, claim or resolve it; the record is read again
  after the remove, and if a new report about that player was filed in the meantime its entry is
  written back.
- `claim(reportId, { by }) -> (ok, reason?)` **(contract)**: needs `reports.resolve`; `"claimed"`
  when another staff member holds it. Audited `"report_claimed"`.
- `resolve(reportId, resolution, { by, note? }) -> (ok, reason?)` **(contract)**: needs
  `reports.resolve`; a report claimed by another staff member can be resolved only by that
  claimer or by staff of a higher rank (`"server"` and `"console"` always), else `"claimed"`; the
  claimer's rank must be known now (`Admin.rankOfChecked`): unknown is `"claimed"` too; `resolution` is `"actioned"`, `"no_action"` or `"dismissed"`; `note` one of
  `Reports.resolveNote.actioned`, `.noViolation`, `.duplicate`, `.insufficient`. Writes an audit
  entry `"report_resolved"` (reason key `Reports.resolution.<resolution>`) through
  `Moderation.record`, **without reporter ids**, and clears the per-target key and its index
  entry.
- The staff calls take `by` like Moderation: `"server"` and `"console"` are trusted, `"system"` is
  refused, a staff Player goes through `Admin.allow` (or the admins fallback). Reasons
  `"no_permission"`, `"rate_limited"`, `"disabled"` (Admin's flag), `"invalid"`, `"not_found"`,
  `"claimed"`, `"failed"`.
- `registerContext(fn(targetUserId, target: Player?) -> { [string]: number | boolean | string }?)`
  **(contract)**: adds game context to a new report (the target's level, zone); also an extension
  for `init`. A string value must be a declared strings key; anything else is dropped. Capped at
  `contextMaxBytes`.
- Signals **(contract)**: `Submitted(reportId, targetUserId, category)` (no reporter),
  `Resolved(reportId, resolution)`.

```
Report = { id ("<targetUserId>-<firstAt>"), at, target, targetName, category (the first report's),
  reporters: { number } (reports.reporters only, else {}), count, distinct,
  notes: { string } (filtered, unattributed, staff only), server (JobId), placeVersion, context: table?,
  status: "open" | "claimed", claimedBy: number? }
```

### Network and client

`net.blink` (RemoteScope `STUDWORK_REPORTS`): the client -> server request is the §9 action
`submit(targetUserId: f64, category: string(1..32), note: string(0..200)?)` (one per 10 s, burst
2; action ids are lowercase: `h:action(player, "Reports", "submit", ...)` in specs); the answer is a `ctx.net.feedback` toast with a key (`Reports.thanks`, or `Reports.disabled`
while the flag is off). The server validates the target (in this server or recently left), the
category and the note length before anything else.

Client: `StudWork.use(Reports).open(targetUserId?)` opens the screen `"Report"` (registered with
`UI.registerScreen` unless the game registered its own): pick a player (this server, then recently
left; never yourself), a category button, an optional note (hidden when `note.enabled` is false),
submit; then the block button when `blockPrompt` is on and the target is in the server.
`.recent()` reads the recently-left list; `.read` is the screen's pure view state. Mobile first
like the panel (667x375, 44 px targets, theme tokens, `UI.text` keys `Reports.*`, no tweens or
animations, so reduced motion is respected by construction).

The staff queue is the **Reports** tab in Admin's panel (`reports.read`, the same viewer rules as
`queue`): 20 rows per page, as many pages as `queue.maxOpen` needs, columns id, when, player (`Name (id)`), category, count, status,
notes, plus reporters (the distinct count) with `reports.reporters`. One page fetch reads at most
two index pages (400 entries) whatever `queue.maxOpen` is: page 1 starts from the top, and the
next pages continue the same staff member's walk for 30 seconds (a claim or resolve in this server
starts it over), so page forward from page 1; a page far past the walk comes back empty until the
pages before it were fetched. Notes and reporter ids are
filled in only on rows the viewer has claimed (at most 3 full reads per page). Row actions:
`claim` and `resolve` (`reports.resolve`; resolve offers the three resolutions and the four note
keys).

### Console

`reports queue [open|claimed]`, `reports detail <reportId>`, `reports claim <reportId>`, `reports
resolve <reportId> <actioned|no_action|dismissed> [noteKey]`, `reports stats` (the server-side
counters, including refused reports).

### Replication

`ctx.replicate.setAll("recent", { { userId, name } })`: the recently-left players (newest first,
at most 50; pruned every 5 s, removed on rejoin), so every client can offer them in the picker;
public facts only. Nothing about reports, reporters or counts is replicated to anyone; staff read
the queue through Admin's tab (`Rows`, to that staff player only).

### Save data and shared store keys

Section `reports`, version 1 (the reporter's own, not replicated): `{ sent = { { target, at } } }`,
at most `limits.sentMax`; it makes the reporter limits hold across servers (reserved before
anything yields).

| Store | Key | Holds |
|---|---|---|
| `ctx.data.shared` | `r/t/<userId>` | the merged open report about one target (with its per-day count for `perTargetPerDay`); closed and deleted when read after `queue.indexExpiryDays` without a write |
| sorted map `queue` | key `targetUserId` | a `ReportSummary`; sort key = priority (distinct reporters, most first, then `at`); expiry `queue.indexExpiryDays`, renewed on every write. The panel lists the queue with `range`, never by rewriting a value |

Resolved reports keep no key of their own: they become an audit entry (no reporter ids). A
report key that is never read or written again after its index entry expired stays in the store
until it is (it is no longer listed anywhere); see the pending file.

## Audit log

```
AuditEntry = { id: string, at: number, server: string (JobId, or "studio"), placeVersion: number,
  by: number (0 = server, console or system), byKind: "staff" | "server" | "system" | "console",
  target: number?, action: string, reasonKey: string?, privateReason: string? (filtered, staff-only),
  seconds: number?, offense: string?, source: string?, status: "ok" | "pending" | "failed" | "refused",
  note: string? (a strings key), details: string? (report details, JSON) }
```

- **What is logged:** every Moderation action (including refused ones, bounded as described in
  Actors), Admin's panel actions through the sink (teleport, spectate, announce, shutdown, grant,
  and refused built-ins), and claimed and resolved reports (without reporter ids), through
  `Moderation.record`.
- **Entry size:** `privateReason` at most `audit.privateReasonMax` characters (the full text goes
  only to `BanAsync`), `details` at most `audit.detailsMaxBytes` encoded, `note` a strings key.
- **Writes are chunked.** Each server appends to its own chunk `a/<day>/<job8>/<seq>` (at most
  `audit.chunkSize` entries, then a new chunk), adds the chunk to the day directory `a/<day>/d`
  once, and appends to the small per-target index `a/u/<userId>`. Entries are buffered in memory
  (at most `audit.bufferMax`; past that the oldest are dropped and the count logged) and flushed
  every `audit.flushSeconds`, only when the buffer isn't empty. A failed flush keeps the buffer
  and retries with backoff; shutdown flushes once more within `audit.shutdownSeconds`. One flush
  runs at a time (the shutdown flush waits for a running one), and entries appended while a write
  yields are kept for the next flush.
- **Retention:** `audit.retentionDays` (default 30, 1..90). A sweep runs once at server start and
  then every 6 hours, by the server that wins the `sweep` lease in the `pending` sorted map: it
  deletes an expired day's chunks listed in its directory key, then the directory key. It starts
  after the persisted marker `a/s` and looks back at most `retentionDays + 7` days, so days missed
  while no server swept are still deleted. A player's index `a/u/<userId>` drops entries older
  than `retentionDays` on each write; an index that is never written again keeps its old entries in
  the store (hidden from every read) until it is. Roblox
  keeps its own ban history independently: unbanning "does not remove their ban history"
  ([Bans](https://create.roblox.com/docs/production/bans)).
- **Who reads it:** `audit.read` staff, through the Audit tab or `Moderation.audit`, at most once
  per `audit.readSecondsPerStaff` per staff member, cached `audit.readCacheSeconds`.
- **What a read costs.** `ctx.data.shared` has no plain read, so every key read is an
  `UpdateAsync`. A day read is therefore bounded: the directory plus `audit.chunksPerRead` chunk
  keys (newest first), whatever the number of servers that logged that day. The Audit tab reads the
  store at most once per request and pages through older chunks from the cache.

## Cross-server behaviour

- **Bans** are Roblox's: `BanAsync` evicts the player "across all servers" and refuses rejoins
  ([Players.BanAsync](https://create.roblox.com/docs/reference/engine/classes/Players#BanAsync)).
  While a ban is pending (a transient Roblox failure), the lease holder retries it, every server
  checks a joining player against the `pending` index, and another server takes over only after
  the lease expired (see "Pending bans and unbans").
- **Kick, mute, unmute, warn, punish** to a player in another server go through
  `ctx.data.messages` (durable: an offline player gets it on their next load; delivery is
  at-least-once, deduplicated by id in `seen`). The send is ProfileStore `MessageAsync`, which
  retries through an outage and may block, so it always runs in its own thread: staff get
  `(true, "sent")` at once. `"sent"` means queued: delivery can take up to an autosave period
  (minutes) when the owning server misses the ping. Mutes and strikes are applied inside the
  target's save update. A messaged mute's end time is absolute, computed when it is sent
  (`now + seconds`), so a late delivery means a shorter mute. A kick older than
  `crossServer.kickMaxAgeSeconds` on arrival is dropped and audited `"failed"`, so a player isn't
  kicked long after on the next join. At most `crossServer.perTargetPerHour` such messages per
  target per hour leave one server, so a staff account can't flood a player's message queue
  (which every module shares). The kit never uses MessagingService directly (the framework
  refuses it to modules): Roblox calls its delivery "best effort and not guaranteed", typically
  1-2 s ([MessagingService](https://create.roblox.com/docs/reference/engine/classes/MessagingService)).
- **Server bans**, **announcements** and **shutdown** are this server only.
- **Reports** are one shared queue: a per-target key plus the `queue` sorted map; staff in any
  server see them.
- **Roles** are resolved per server at join; there is no shared staff list. Per-staff limits are
  per server too.

## Safety and abuse

Moderation tools are themselves an attack surface: players use reports to harass, and staff
accounts get stolen or misused. The kit is built to keep each of those bounded.

- **Harassment through reports.** A group can mass-report a player to get them punished. Reports
  never punish by themselves: `autoAction` is off by default, and when on it needs
  `distinctReporters` different reporters in a window and can only take `auto.permissions`
  actions (no ban). Per-pair, per-reporter and per-target limits cap what one player or a group can
  file, and the reply never says when they were capped. These caps are per account: a group
  using many alt accounts can still file many reports, push single-reporter reports out of a full
  queue and fill a target's 20-note cap first (known issue; watch `reports stats` for evictions).
- **Staff abuse.** Roles with ranks (no upward or self action, also for targets in other servers),
  per-role `maxBanSeconds` and `maxMuteSeconds`, permanent bans behind their own permission,
  per-staff rate limits, every action (and every refused request, bounded) audited with the actor,
  and the Admin `flag` to strip all staff powers at once without a restart.
- **Fail closed.** `by` is required; an unknown target rank refuses the action; a non-transient
  ban error is a failure, not a silent pending; a free text that can't be filtered is refused.
- **Reporter privacy.** Reporter ids are shown only to `reports.reporters` staff (owner and admin
  by default); others see a count. Notes are unattributed. A staff member never sees reports about
  themselves or about staff of equal or higher rank. Reporters are never in any non-staff client's
  state or events, never in signals, and left out of the report audit entries. The reported player
  is told nothing.
- **Unfiltered text.** Every free-text field a staff member or player types (report notes,
  announcements, free ban and kick messages, private reasons) is filtered `"public"` at submission
  and only the filtered string is stored or shown; without TextFilter it is refused (notes:
  dropped). Context and data-view values are numbers, booleans or declared strings keys. **Cells
  of a tab you register** (`registerTab`) are sent as you return them (strings up to 200
  characters): they must be numbers, booleans, strings keys or text you already filtered; never
  put a player-typed name or bio there unfiltered. Games must
  filter "any displayed text that you don't have explicit control over"
  ([Text filtering](https://create.roblox.com/docs/ui/text-filtering)), and "staff only" is no
  exemption. Raw private reasons go only to Roblox's `PrivateReason`. Text passed by trusted code
  (`"server"`, `"console"`, `"system"`) is not filtered, so **never forward player-typed text with
  a trusted actor**: pass the staff Player as `by`.
- **What Roblox already does.** The kit adds to Roblox's systems, it doesn't replace them:
  players can report and block through Roblox's own menus (creators see only aggregate report
  analytics, [Safety](https://create.roblox.com/docs/safety)); Roblox moderates accounts and
  content itself; and Roblox handles platform appeals but "will not mediate" appeals of your game
  bans unless your rules break the Community Standards
  ([Users and players: ban guidelines](https://create.roblox.com/docs/players#ban-guidelines)).

| Case | How it's stopped |
|---|---|
| A group mass-reports one player | `perPairPerDay`, `perReporterPerHour/Day`, `perTargetPerDay`; `autoAction` off by default; no automatic ban |
| A player spams reports | the same "thanks" for every outcome, server-side counters, durable `sent` list across servers |
| False reports fill the queue and push out real ones | at `queue.maxOpen` the lowest-priority report (fewest distinct reporters, oldest) is evicted, so widely reported targets stay; many alt accounts can still crowd out single-reporter reports (known issue) |
| A client fakes a staff request | staff check first; a non-staff request is dropped with no reply; Net rate limits |
| A client replays a row action on a report it wasn't shown | the row id must be one the server sent that staff member for that tab |
| A client reads the staff list | never replicated; non-staff state has no `staff` key; the panel code isn't sent to them |
| An exploiter reads the anti-cheat thresholds | put them in `ServerConfig.Moderation.autoSources` (server-only); `config.*` is public |
| Game code forwards a client request and forgets `by` | `by` is required; `nil` raises an error, so nothing runs with server power by accident |
| Game code forwards a player's text with `by = "server"` | not filtered (developer text): pass the Player as `by` so the text is filtered |
| A moderator bans an admin, or themselves | `"outranked"`; self-action is refused in Studio too (the outranked check is skipped there only for `studioRole`-only targets) |
| A moderator acts on an admin whose group role hasn't resolved yet | `rankOfChecked` is unknown: `"unknown_rank"`, and reports about them are hidden (also when the report was filed before they were promoted: a rank from filing time is never used) |
| A moderator bans an admin who is offline or in another server | `Admin.rankOfUserId` looks the target up; a failed lookup refuses with `"unknown_rank"` |
| A moderator bans permanently or for a year | `ban.permanent` needed; `maxBanSeconds` (`"too_long_for_role"`) |
| A helper mutes someone for a week | the role's `maxMuteSeconds` (helper 1 h, moderator 1 day: `"too_long_for_role"`) |
| A stolen staff account bans everyone | `limits.bansPerHour`, `actionsPerMinute`; the audit names the actor (bans also in the actor's own index); the Admin `flag`. Limits are per server: a hop resets them (known issue) |
| A staff account probes for permissions it lacks | each refused request is audited once per (staff, action) per `audit.refusedEverySeconds` |
| A staff account floods an offline player with warns | at most `crossServer.perTargetPerHour` cross-server messages per target per hour per server (`"rate_limited"`), so other modules' queued messages (Mail) aren't pushed out |
| A reported moderator sees who reported them | reports about the viewer or equal/higher staff are hidden; reporter ids need `reports.reporters` |
| An anti-cheat false positive bans a player | `"system"` may only warn, mute or kick unless you add `ban` to `auto.permissions` |
| A cheater trips a heuristic over and over to flood the audit | refused system actions are audited at most once per (target, source) per `audit.refusedEverySeconds`; the audit is chunked per server, so no day key fills up |
| A ban is undone while it is still pending | the unban replaces the pending entry in the same write; retries apply only the latest `seq` |
| The reported player learns who reported them | reporter ids exist only in staff-only records |
| Staff type abuse into an announcement, ban or kick message or a private reason | TextFilter `"public"`, or refused |
| Game data with player text (a pet name) shows up in the panel | context and data-view strings must be declared keys; other strings are dropped. A registered tab's cells are the game's responsibility (filter them) |
| A ban made in the Creator Hub carries text into `history` | only preset texts are shown; others show `Moderation.history.custom` |
| A ban message names a person or links a server | presets by default; free text is opt-in, filtered and length-capped; follow Roblox's message rules below |
| Grant currency used to print money | `data.grant` (owner only by default), amount 1..`grant.max`, currencies from `grant.currencies` (paid currencies only when listed), audited |

## What Roblox doesn't allow (or doesn't offer)

- **No API opens Roblox's Report Abuse menu**, for a player or at all: `StarterGui:SetCore` has no
  report option, only `PromptBlockPlayer` and friends
  ([StarterGui.SetCore](https://create.roblox.com/docs/reference/engine/classes/StarterGui#SetCore)).
  Reports therefore keeps its own queue and offers the block prompt after a report.
- **Ban messages** (`DisplayReason`, at most 400 characters and text filtered by Roblox) may carry
  appeal or contact information, but "mentions of personal information or direct links are not
  allowed", including "a specific username or handle, or ... a direct link to a Discord server or X
  account" ([message guidelines](https://create.roblox.com/docs/players#message-guidelines)).
  "Visit the Discord in my group/game page" is fine. Private details go in `PrivateReason`, which
  is "never shared with the client"
  ([Players.BanAsync](https://create.roblox.com/docs/reference/engine/classes/Players#BanAsync)).
- **State your rules and offer appeals.** "Creators must clearly state their game rules somewhere
  accessible to all users" and apply them "fairly and not arbitrarily"; `BanAsync` asks you to
  "provide a way for them to appeal" ([ban guidelines](https://create.roblox.com/docs/players#ban-guidelines)).
  Set `Moderation.ban.appeal`.
- **Bans in Studio** can be tested, "but the bans will not apply to production"; `UnbanAsync` makes
  no requests outside production (input is still validated). `Players.BanningEnabled` can only be
  set in Studio's Players properties, not from Luau
  ([Players](https://create.roblox.com/docs/reference/engine/classes/Players#BanningEnabled)); the
  kit warns at start when it is off.
- **`GetBanHistoryAsync`** "will only succeed on production servers", never in Studio
  ([Players.GetBanHistoryAsync](https://create.roblox.com/docs/reference/engine/classes/Players#GetBanHistoryAsync)):
  `history` returns `"unavailable"` there.
- **Kick messages** are at most 500 bytes; a longer one "is discarded and the user sees the
  default notice" ([Player.Kick](https://create.roblox.com/docs/reference/engine/classes/Player#Kick)).
  The kit cuts to `kick.maxLength` (at most 500) on a UTF-8 boundary.
- **Platform-integrated chat** becomes required for all games in May 2027. With it, message text
  is unavailable to game code and `OnIncomingMessage`/`Chatted`-based moderation is unsupported;
  whether `TextSource.CanSend` still applies is not documented
  ([Platform-integrated chat](https://create.roblox.com/docs/chat/platform-integrated-chat)). The
  kit never reads chat text, so it isn't affected by that part; the text mute may stop working and
  must be checked live. Platform chat gives players Roblox's own reporting and muting.
- **Group ranks:** `Player:GetRankInGroup` and `GetRankInGroupAsync` are deprecated; the kit uses
  `GroupService:GetRolesInGroupAsync`
  ([Player.GetRankInGroupAsync](https://create.roblox.com/docs/reference/engine/classes/Player#GetRankInGroupAsync)).
- **Rate limits** for `BanAsync`, group lookups and ban history are not documented; the kit backs
  off on failure and budgets group lookups.

## Guardrails it relies on

- Hard rule 3 (server authority): every client request is a §9 action checked server-side
  (staff, permission, rank, arguments); the client never decides who is staff.
- Hard rule 4: no raw remotes (`net.blink` per module); no `DataStoreService` or MessagingService
  (`ctx.data.shared`, `ctx.data.sortedMap`, `ctx.data.messages`); engine services through
  `ctx.services.get` (`Players`, `GroupService`, `TextChatService`, which the framework adds to
  `Services.ALLOWED`).
- Hard rule 5: every number above is a config key with its default in `module.luau` (operational
  sizes like the 200-entry sorted map page stay constants in code).
- `textfilter`: report notes, announcements and free messages reach players only through
  TextFilter.
- `strings`: no hard-coded English in the client parts or the panel.
- `special`: the kit's event names avoid names the framework uses (hence `RunResult`, not
  `Result`).
- A proposed optional `moderation` lint check would flag `:Kick(` and `BanAsync` outside the
  Moderation module (see the pending file); not part of this release.

## Override levels

1. **Use the defaults:** list the modules, put your staff in `ServerConfig.Admin`, set the appeal
   line, add TextFilter (and raise its `maxLength`) if you want free text and notes.
2. **Config:** roles and ranks (`maxBanSeconds`, `maxMuteSeconds`; merged over the defaults),
   limits, `grant`, `announce`, `shutdown` presets, ladders and offences, mute and ban lengths and
   the panel's duration choices, report limits, categories and queue size, audit retention,
   `autoAction`; anti-cheat thresholds in `ServerConfig.Moderation.autoSources`.
3. **Replace a piece:** your own preset keys and wording (`GameConfig.strings`), your own
   `"Report"` or `"ModerationNotice"` screen (`UI.registerScreen`) or notice UI (`onNotice`),
   registered permissions, panel actions, tabs and data views (`registerPermission`,
   `registerAction`, `registerTab`, `registerDataView`), your own panel text filter
   (`registerTextFilter`), report context (`registerContext`), and `Moderation.report` from your
   own anti-cheat.
4. **Switch one off:** leave it out of `modules` (the others fall back as described above), or use
   its `flag` live. Saved strikes, mutes and the shared stores stay where they are.
5. **Write your own module:** call `Moderation.ban/kick/mute` (with `by`) and `Admin.allow` from
   it, write audit entries with `Moderation.record`, or build your own staff tools against the
   same public API.

## Failure behaviour

| Situation | Behaviour |
|---|---|
| `BanAsync` fails transiently (`"failure for UserId"`, timeout, HTTP) | the player is kicked here; the ban goes to `bans/p/<userId>` and the `pending` index, is audited `"pending"` and retried with backoff by the lease holder (another server after the lease expires); a joining listed player is kicked; then audited `"ok"`, or `"failed"` after `retry.maxAttempts` |
| `BanAsync` fails transiently and the shared store is down too | `"pending"`, kept in this server's memory only (note `Moderation.note.pendingUnsaved`), retried by this server and saved when the store is back |
| `BanAsync` fails otherwise (banning disabled, bad input) | `(false, "failed")`, audited; never pending |
| `Players.BanningEnabled` is off | a warning in the log at start; every ban then fails as above |
| `UnbanAsync` fails transiently | a pending `"unban"` entry, retried the same way; status `"pending"`; it replaces any pending ban |
| A ban fails, then an unban, then the outage ends | the player stays unbanned (only the latest `seq` is applied) |
| The shared store is down | audit entries stay buffered (at most `audit.bufferMax`, oldest dropped and counted) and retry; pending writes retry; a report submit returns `"failed"` (the reporter still sees "thanks"); at a join an unreadable `pending` index follows `onUnknownStatus` |
| A sorted map read fails | the index scan tries again next time; a join follows `onUnknownStatus`; the queue reads as empty |
| A sorted map index entry expires before its work is done | it is renewed while work remains; see known issues in the pending file |
| A group lookup fails or is over budget | not staff (or the cached role) until the re-check `groupRetrySeconds` later; as a target, that player's rank is unknown, so actions on them are refused with `"unknown_rank"` and reports about them are hidden |
| `ctx.data.messages` is slow or blocked (DataStore outage) | the send runs in its own thread, staff get `"sent"` at once; the action applies when it arrives (or on the next load); a kick older than `kickMaxAgeSeconds` is dropped and audited `"failed"`; a send that fails is audited `"failed"`; duplicates are ignored |
| Too many messages to one target | over `crossServer.perTargetPerHour` from one server: `"rate_limited"` |
| TextFilter missing | free ban and kick messages `"invalid"`, staff `privateReason` `"no_filter"`, free panel text and announcements `"no_filter"`; report notes dropped, the report filed |
| TextFilter refuses or fails a text (too long for `TextFilter.maxLength`, rate limit, policy) | that text is refused (Moderation `"invalid"`, Admin `"failed"` or `"rate_limited"`) or dropped (notes), never stored or shown unfiltered |
| A caller omits `by` | an error naming the fix (`by = "server"`); nothing runs |
| An action is refused | audited `"refused"`, at most once per (target, source) for `"system"` or per (staff, action) for staff, per `audit.refusedEverySeconds`; no strike recorded |
| The audit is read too often | `"rate_limited"` (one read per `audit.readSecondsPerStaff` per staff); otherwise a cached result up to `audit.readCacheSeconds` old (plus this server's own newer entries) |
| The queue is full (`queue.maxOpen`) | the lowest-priority report is evicted; the new one is filed (or dropped if it is the lowest) |
| Server shutdown | pending writes and the audit flushed within `audit.shutdownSeconds`; a pending ban stays in the index for another server |
| `history` in Studio | `(false, "unavailable")` |
| Admin `flag` off | nobody is staff, the panel and `staff` state removed; `"server"` and `"console"` still act |
| Moderation `flag` off | every action returns `"disabled"`, `report` returns false; joins unaffected; pending retries keep running |
| Reports `flag` off | `submit` returns `"disabled"`; `open()` does nothing; the queue stays readable and resolvable by staff |
| A player can't receive chat (`AddUserAsync` returns nil) | no `TextSource` to mute; the mute still stands in the save and is applied if one appears |

## Tests (mocked)

Fakes for `Players` (`BanAsync`, `UnbanAsync`, `GetBanHistoryAsync` with Roblox-like validation,
failure injection with transient and non-transient messages, `BanningEnabled`), `GroupService`,
`TextChatService` and a fake `PlayerGui` live in `packages/kits/moderation/tests/Fakes.luau`,
passed as `harness({ services = { ... } })`; the framework ships no moderation fakes. Spec files in
`packages/kits/moderation/tests/`:

- `Foundation.spec.luau`: the three definitions, config shapes, optional deps, the actor rule, the
  fakes.
- `AdminRoles.spec.luau`, `AdminPermissions.spec.luau`, `AdminRequests.spec.luau`,
  `AdminActions.spec.luau`, `AdminPanelState.spec.luau`: users map and group rules (cache, budget,
  failure re-check), Studio everyone staff, live none unless configured, `rankOfUserId`,
  `limitsOf`, every permission boundary, `allow` and the per-staff limits, a non-staff client
  sending each request (`h:action`) gets no reply, no `staff` key in non-staff state, the panel
  delivered only to staff, the outranked rule, row-id and argument checks, each built-in action
  (grant bounds, paid currencies), refused-audit throttling, the panel's view state.
- `Moderation.spec.luau`: a call without `by` raises; a ban during an outage (fails n times ->
  pending, audited, retried, then ok; play continues); a non-transient error is `"failed"`, never
  pending; ban fails -> unban -> outage ends -> the player stays unbanned; `maxAttempts`; the store
  down too (`pendingUnsaved`); unban; history; kick here and cross-server, the stale-kick drop and
  the per-target message cap; mutes across two servers with dedupe; the ladder from start to
  finish, with no strike for a refused step, and for an absent target; an automatic report that
  would ban is refused and audited once per hour; audit chunking, buffer cap, failed flush,
  shutdown flush and retention; Admin off, Studio, `unknown_rank`, role caps, the panel actions and
  the Audit tab; the flag.
- `Reports.spec.luau`, `ReportsStaff.spec.luau`, `ReportsClient.spec.luau`: each spam limit;
  duplicate merge; the per-target cap; `maxOpen` eviction; the reporter id never in any non-staff
  client's state or sent events; reporter ids only with `reports.reporters`; a reported
  moderator's queue doesn't contain the report; notes only through `detail`; `autoAction` off by
  default; the Report screen's view state.
- `AdminHardening.spec.luau`, `ModerationHardening.spec.luau`, `ReportsHardening.spec.luau`,
  `IntegrationHardening.spec.luau`: `rankOfChecked` (unknown while a lookup failed, never a lookup
  for a user id), bans-only `bansPerHour`, spectate cleared on leave; bounded audit reads (store
  updates counted per read), the TTL-only cache, retention on read and on write, the sweep marker,
  flush races; ladder `key` and `warnKey`; an absent punish refused when `limitsOf` errors; the
  Reports viewer rule with an unknown rank (also for a target reported before a promotion), the
  whole queue past 200 entries, ghost and stale entries (a submit racing a ghost drop keeps its
  entry), claimer-only resolve (an unknown claimer rank is never overridden), at most two index
  reads per tab fetch; and, with the real Admin and a failing `GroupService` fake, unknown ranks
  failing closed in Moderation and Reports, reports hidden once the group cache expires, summaries
  without extra fields, and the sender's role caps on an absent-target punish.
- `Integration.spec.luau`, `ModerationSim.spec.luau` (multi-server simulations: outage ban, mute
  and kick reaching a second server, full ladder, report spam, faked requests, the staff list never
  in non-staff state) and a bench variant with the three modules at 50 players
  (`tests/bench/ModerationBench.luau`).

**From a game's own specs.** The fakes are plain Luau and work from a game: in a single-game
project the path is `studwork/packages/kits/moderation/tests/Fakes.luau` (a games repo:
`roblox-core/packages/...`), relative to the project root where `tools/test` runs. Kit action ids
are lowercase (`"submit"`, `"run"`, `"fetch"`, `"panelOpen"`) when you call `h:action`.

**Spec strictness.** The specs the tools generate (`GameModule.spec.luau` from `tools/new-game` /
`tools/new-project`, `tools/make-module`'s `tests/`) start with `--!nocheck`, and that is the
convention for specs: they run in Lune and aren't in the Rojo sourcemap, so luau-lsp can't resolve
`require(script.Parent.ServerConfig)` (the line [testing.md](../testing.md) uses) or a string
require such as the Fakes path ("Unknown require"). Keep `--!nocheck` in a spec that requires
`ServerConfig`. If you want a spec `--!strict`, cast every such require, `(require :: any)(...)`,
including `ServerConfig`; `tools/typecheck` then checks the rest.

**Notes need a content-sharing policy in specs.** `TextFilter.respectContentSharing` is on by
default, and the harness knows no player's `PolicyService` answer, so a report note (or a staff
announcement) from a player whose policy is unknown is dropped (the report itself is still filed).
Give the authors a policy:

```lua
local h = StudWork.test.harness({
	modules = modules, config = config, serverConfig = ServerConfig,
	policy = { [reporterId] = { IsContentSharingAllowed = true } }, -- one entry per note author
	services = { TextService = StudWork.test.fakes.textService(), GroupService = Fakes.groupService(),
		Players = Fakes.players(), TextChatService = Fakes.textChatService() },
})
```

A game whose `ServerConfig.Admin.groups` is set needs a `GroupService` in its `Boot.spec.luau`:
the sim has none, so the role lookup fails and `bootWarnings` is not empty. Pass the fake through
`bootGame`'s `services` option (forwarded to the sim server like the harness's):

```lua
local StudWork = require(game:GetService("ReplicatedStorage"):WaitForChild("Framework"))
local F = StudWork.test.sim
local Fakes = (require :: any)("studwork/packages/kits/moderation/tests/Fakes.luau")

local r = F.bootGame("default.project.json", { services = { GroupService = Fakes.groupService() } })
expect(r.bootWarnings).toEqual({})
```

Add `Admin`, `Moderation` and `Reports` to the spec's expected module list as well.

## Not verifiable offline

Real `BanAsync` and its ban modal on join, alt-account propagation and device blocking; which real
`BanAsync` errors are transient; real cross-server latency of `ctx.data.messages`; group ranks from
a real group; voice mute through `AudioDeviceInput` access lists; `TextSource.CanSend` under
platform-integrated chat; the panel's feel on a phone. These go on the live checklist in
[manual-qa.md](../../manual-qa.md) (entries proposed in the pending file).
