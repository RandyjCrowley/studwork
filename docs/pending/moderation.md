# Pending shared-file changes: moderation kit

The moderation kit's branch may not edit shared files (CHANGELOG, module-api, module-reference,
kit-contract, guardrails, decisions, known-issues, manual-qa, the `--modules` order, templates,
the sandbox, the docs indexes). This file holds the text each of them needs; the maintainer
merges it at release time and deletes this file. The kit page is
[docs/framework/kits/moderation.md](../framework/kits/moderation.md). Version placeholders say
`v1.8.0`; adjust to the actual release.

## CHANGELOG entry (`CHANGELOG.md`, `[Unreleased]`)

```markdown
### Added

- **Moderation kit** (`packages/kits/moderation/`; [docs](docs/framework/kits/moderation.md)): three
  modules that each work alone.
  - **Admin**: staff roles with ranks and permissions from `ServerConfig.Admin` (users and group
    roles through `GroupService:GetRolesInGroupAsync`, cached and budgeted), a staff panel delivered
    only to staff (Players, Announce, Data tabs; teleport, spectate, announce, shutdown, grant
    currency, data view), per-staff rate limits, extensions other modules use to add permissions,
    actions, tabs, data views, an audit sink and a text filter. `allow` (permission plus per-staff
    limits; only real bans count toward `bansPerHour`), `rankOf`/`rankOfUserId` (rank of a present
    or absent user), `rankOfChecked` (the rank only when known without a group lookup; nil =
    unknown, so callers fail closed), `studioRoleOnly` and `limitsOf` (role caps).
    Studio: everyone is staff; live: nobody unless configured. Optional Economy and TextFilter.
  - **Moderation**: `ban`/`unban` through `Players:BanAsync`/`UnbanAsync` (a transient failure
    kicks locally and goes to a per-user pending entry with a sequence number and a lease, found
    through a sorted map index; other errors fail), `history`, `kick` (cross-server through
    `ctx.data.messages`), `serverBan`, `mute`/`unmute` (text chat `CanSend`, optional voice),
    `warn`, offence ladders with decaying strikes (`punish`), an automatic hook (`report`) bounded
    to warn/mute/kick, `record` for other kit modules' audit entries, and a retained audit log
    chunked per server in `ctx.data.shared` (a day read touches at most `audit.chunksPerRead`
    chunks, paged; a target read one key). Ladder steps may name their message (`key`), offences
    their warning (`warnKey`). Every mutating call takes a required actor
    (`by = Player | "server" | "console" | "system"`).
  - **Reports**: a mobile-first report screen, rate limits per reporter, pair and target, merged
    duplicates, filtered unattributed notes, reporter ids only for `reports.reporters` staff, no
    reports about the viewer, higher staff or staff whose rank is unknown, the staff queue (a
    sorted map index, paged up to `queue.maxOpen`; claimed reports resolved by the claimer or a
    higher rank) as an Admin tab
    and through `queue`/`detail`/`claim`/`resolve`, optional auto-action through Moderation (off by
    default), the block prompt after a report.
- `ctx.services.get` allows `GroupService` and `TextChatService` (module-api §24.1).
- `tools/new-game --modules` and `tools/new-project --modules` know `Admin`, `Moderation` and
  `Reports` (listed after the template's modules; the NewGame spec now counts 18 kit modules).
```

## decisions entries (`docs/decisions.md`)

```markdown
## v1.8.0 (moderation)

- **Three modules, Admin at the base.** Refs can't cycle, so Admin names neither of the others;
  Moderation and Reports declare it optional and register their panel actions, tabs and the audit
  sink into Admin's extensions in `init`. Each module works alone with a documented fallback
  (permissions from `ServerConfig.<Module>.admins`, audit to `ctx.log`).
- **Bans are Roblox's `BanAsync`, universe-wide.** It evicts across servers, refuses rejoins and
  covers suspected alts by default (https://create.roblox.com/docs/reference/engine/classes/Players#BanAsync).
  A universe unban doesn't lift a place ban (…#UnbanAsync), so the kit only bans universe-wide.
  `BanAsync` can fail (HTTP, throttling; no documented rate), so a failed ban kicks locally and goes to
  a shared pending list any server retries.
- **Ban messages are preset keys.** Roblox forbids handles and direct links in `DisplayReason` and
  asks for public rules and an appeal path (https://create.roblox.com/docs/players#message-guidelines,
  https://create.roblox.com/docs/players#ban-guidelines); presets plus a game-set appeal line make
  that the default. Free text is opt-in and filtered.
- **Group roles through `GroupService:GetRolesInGroupAsync`.** `Player:GetRankInGroup(Async)` is
  deprecated and returns only the highest public role; role ids are stable, ranks don't define the
  hierarchy (https://create.roblox.com/docs/reference/engine/classes/GroupService#GetRolesInGroupAsync,
  https://create.roblox.com/docs/reference/engine/classes/Player#GetRankInGroupAsync).
- **Cross-server actions through `ctx.data.messages`, not MessagingService.** MessagingService is
  best effort (https://create.roblox.com/docs/reference/engine/classes/MessagingService) and
  refused to modules; messages are durable and reach an offline player on the next load.
- **Text mute through `TextSource.CanSend`** (https://create.roblox.com/docs/reference/engine/classes/TextSource);
  the kit never reads chat text, which platform-integrated chat (required from May 2027) removes
  (https://create.roblox.com/docs/chat/platform-integrated-chat).
- **Own report queue.** No API opens Roblox's Report Abuse menu; `SetCore("PromptBlockPlayer")` is
  the closest flow (https://create.roblox.com/docs/reference/engine/classes/StarterGui#SetCore).
- **Automatic actions never ban by default** (`auto.permissions = warn, mute, kick`): a false
  positive in a heuristic must not cost a player their account access.
- **The panel's code ships in the server part** and is cloned into staff PlayerGuis only, so
  non-staff clients never receive staff UI or the action list.
- **The actor is required** (`by = Player | "server" | "console" | "system"`; `nil` raises). A
  forgotten argument must never mean "trusted": that would give any forwarded client request
  owner power with no rank check or limits.
- **Fail closed on rank.** A target outside this server gets its rank from
  `Admin.rankOfUserId` (users map, then group lookup); if that fails, the action is refused
  (`"unknown_rank"`), so a moderator can't act on an offline admin.
- **No hot shared keys.** `ctx.data.shared` has only `update`, so every "read" is a full write and
  `return nil` deletes. The audit is chunked per server (`a/<day>/<job8>/<seq>`, 100 entries) with
  a day directory and a small per-target index; pending bans and open reports are per-user keys
  found through sorted map indexes (`range`/`get` are reads). One global key per day or per queue
  would exceed the 4 MB value limit and the per-key write rate in a large game.
- **Pending entries carry `kind`, `seq` and a lease.** An unban replaces a pending ban in the same
  write, retries apply only the latest `seq`, and only the lease holder retries, so a late retry
  can't re-ban an unbanned player and an incident doesn't make every server call `BanAsync`.
- **Only transient `BanAsync` errors are retried** (`"failure for UserId"`, timeout, HTTP);
  anything else (banning disabled, bad input) fails at once, so nothing is "pending" forever.
- **Free text is filtered at submission or refused**, including private reasons (the raw text
  goes only to `BanAsync`'s `PrivateReason`); context and data-view strings must be keys. Staff are
  players too, and "staff only" is not an exemption from Roblox's filtering rule.
- **Reporter ids need `reports.reporters`** (owner, admin), and nobody sees reports about
  themselves or higher staff, so a reported helper can't retaliate.
- **Anti-cheat thresholds may live in `ServerConfig.Moderation.autoSources`**: everything in
  `config.*` replicates to clients.
- **Client requests are §9 actions**, not `handleEvent` events: actions are scoped per module (no
  global name clash) and `h:action` reaches them in specs.
- **Distinct success statuses.** `kick`, `mute`, `unmute`, `warn`, `serverBan` return `"done"`
  (applied in this server) or `"sent"` (queued through `ctx.data.messages`); `ban`/`unban`
  `"banned"`/`"unbanned"`/`"pending"`; `punish` returns the step and the inner status, and
  `(true, "sent", "sent")` for an absent target (the step is chosen where the save is). Callers
  can tell "done" from "will happen" without a second call.
- **`Admin.allow` counts, `Admin.can` doesn't, and each staff action is counted once.** The module
  API counts (`allow`); Admin's own request handling counts its built-in actions and a registered
  tab's fetch, and only checks the permission before a registered action or row action, whose
  `run` calls the module API with `by = staff`. Without that split one click would be counted twice
  against `actionsPerMinute`.
- **Role caps through `Admin.limitsOf(staff)`.** Moderation needs a role's `maxBanSeconds` and
  `maxMuteSeconds` but must not read Admin's config; a small read-only API keeps the boundary.
- **Every tunable number is config** (Addendum C): the audit sizes and rates
  (`audit.chunkSize`, `bufferMax`, `privateReasonMax`, `detailsMaxBytes`, `readSecondsPerStaff`,
  `readCacheSeconds`, `refusedEverySeconds`, `shutdownSeconds`), `crossServer.perTargetPerHour`,
  `pending.indexExpiryDays`/`pollSeconds`, `Reports.queue.maxOpen`/`indexExpiryDays`,
  `Admin.grant.max`/`currencies`, the panel's duration choices. `audit.maxPerDay` and
  `Reports.retentionDays` were dropped: chunked writes have no daily cap to enforce, and resolved
  reports live only as audit entries, so audit retention governs them.
- **`queue()` returns index summaries; `detail()` reads one report.** Reading every `r/t/<userId>`
  key to list the queue would be a full DataStore write per report (no shared `get`); the sorted
  map `range` is a read, and notes and reporter ids are read only for the one report a staff member
  opens.
- **A pending ban survives a store outage in memory.** If `BanAsync` and both pending writes fail,
  the status stays `"pending"` (the player is kicked and refused here, the audit notes
  `pendingUnsaved`) rather than `"failed"`: the ban was meant and is retried as soon as the store
  is back.
- **A messaged mute's end is absolute** (`now + seconds` at send): a delayed delivery shortens the
  mute rather than extending a punishment past what staff chose.
- **Retention sweep once per start and every 6 hours, under a lease** (`sweep` in the `pending`
  sorted map), so one server does the deletes and a quiet game still expires its audit.
- **Refused staff requests are audited** (once per (staff, action) per
  `audit.refusedEverySeconds`), like refused automatic actions: probing for powers shows up in the
  log without letting a loop flood it.
- **Trusted actors' text is developer text.** `"server"`, `"console"` and `"system"` pass text the
  game wrote, so it isn't filtered; only text from a staff Player goes through TextFilter. The page
  tells games never to forward player-typed text with a trusted actor.
- **Studio skips the rank rule.** In Studio everyone has `studioRole`, so every staff action would
  be `"outranked"`; the rule is skipped there and specced with `isStudio = false`.
- **Admin may use TextFilter itself** (optional dependency, Addendum F), with `registerTextFilter`
  as an override hook: announcements and free panel text work with Admin + TextFilter alone.
- **Role config merges over the defaults.** `config.Admin.roles` goes through the framework's deep
  merge like every config table: a game changes a field of a role without restating it (lists such
  as `permissions` replace).
- **`serverBan` and `unban` need `ban`**, and `history` returns a plain list of `HistoryEntry`; the
  first draft named no permission for them.
- **Kit event `RunResult`, not `Result`.** The `special` guardrail refuses kit event names that
  appear in framework code, and the framework has a `Result` type.
- **Unknown rank fails closed everywhere** (final review H1). `Admin.rankOf` answers 0 for a player
  whose group lookup hasn't finished, and Moderation and Reports used it as "not staff". Rather
  than change `rankOf` (frozen), Admin gained `rankOfChecked -> number?` (nil = unknown, never a
  group lookup); the rank rule refuses `unknown_rank` and the Reports viewer rule hides the report.
  The Reports viewer rule never spends `groupLookupsPerMinute` (in-server and cached ranks only),
  so a busy Reports tab can't starve staff role resolution.
- **No rank remembered from filing time** (delta review, fix 2). The first fix stored the target's
  rank with the report and used it when Admin didn't know the current rank; a player reported as
  rank 0 and promoted later then stayed visible to lower staff, and a claimer's stale stored rank
  let a lower rank override them. Reports now uses only the current rank (`rankOfChecked`): unknown
  hides the report and refuses the resolve override; the field is gone from records and summaries
  (`queue()` returns the documented `ReportSummary` fields only). Cost: with group roles, reports
  about players who left are hidden from staff once Admin's group cache expires (known issue
  below); trusted code and the console still see them.
- **Caps unknown = no absent punish** (fix 2). When `Admin.limitsOf` errors, an absent-target
  punish is refused (`"failed"`, audited) instead of being sent without caps.
- **Ghost drops re-check after the remove** (fix 2). A sorted map has no conditional remove (an
  `update` returning nil cancels), so `dropGhost` removes only while the record is closed and then
  reads the record again: a submit writes its record before its index entry, so an entry removed by
  a racing submit is found and written back.
- **The Reports tab's reads per fetch are fixed** (fix 2): at most two index `range` reads per
  fetch, page 1 starts a walk and later pages resume the staff member's walk for 30 s, so the cost
  of a page click doesn't grow with `queue.maxOpen` (no schema cap needed).
- **Audit reads are bounded** (final review H2). Every `ctx.data.shared` read is an `UpdateAsync`
  write, so a day read that touched every server's chunk cost one write per server. A day read now
  touches the directory plus `audit.chunksPerRead` (4) chunks, paged; the cache is time-only; the
  Audit tab reads the store at most once per request. `ctx.data.shared.get` (§24.3) remains the
  real fix.
- **Only bans count toward `bansPerHour`.** `Admin.allow` gained an optional `action` argument
  (additive): unban, server ban and history check the `ban` permission without using the ban
  allowance.
```

## known-issues entries (`docs/known-issues.md`)

- **Framework console commands ignore Admin roles.** `economy grant`, `data dump` and the other
  framework commands keep the framework's admin rule; no hook lets a module govern them
  (proposal below).
- **Admin off: per-module admin lists.** A module can't read top-level `ServerConfig.admins`, so
  `ServerConfig.Moderation.admins` and `ServerConfig.Reports.admins` are separate lists.
- **A role is fixed for the session.** A group demotion applies on the next join (the Admin `flag`
  is the emergency switch).
- **Text mute under platform-integrated chat is unverified** (`CanSend` isn't documented either way).
- **Voice mute is unverified live** (`AudioDeviceInput` access list from the server).
- **No numeric rate limits documented** for `BanAsync`, `GetBanHistoryAsync` or group lookups; the kit
  backs off and budgets, but the right budget is unknown.
- **No read on `ctx.data.shared`.** The kit's "reads" of shared keys (the audit day directory,
  the per-target audit index, `bans/p/<userId>`, `r/t/<userId>`) are `update`s returning `old`,
  i.e. full writes that spend the per-server DataStore budget player saves also use. The kit avoids
  polling them (sorted map indexes instead), rate-limits audit reads (one per 5 s per staff,
  cached 30 s) and bounds a day read to the directory plus `audit.chunksPerRead` chunks, so older
  chunks of a busy day need more pages. Proposed framework fix: `ctx.data.shared.get(key)`
  (module-api §24.3 below).
- **Per-staff limits are per server.** `actionsPerMinute` and `bansPerHour` live in one server's
  memory; a staff member who hops servers gets a fresh count. Bans are also recorded in the staff
  member's own audit index (`a/u/<staffUserId>`), so a spree shows up in one place.
- **Sorted map index entries expire.** The `pending` and `queue` indexes use a 7-day expiry. A
  pending entry is renewed while it is retried; an open report not touched for 7 days drops out of
  the queue index and is closed: the next read or report of that target deletes or restarts its
  per-target key (reporter ids dropped). A key that is never touched again stays in the store
  (unlisted); likewise an audit index `a/u/<userId>` drops expired entries only on its next write
  (every read hides them). A periodic sweep of both would need a key listing the store doesn't
  offer.
- **Admin off: no per-staff limits.** With Admin off, `ServerConfig.<Module>.admins` staff are not
  rate-limited by the kit (`actionsPerMinute`, `bansPerHour` live in Admin; Net limits cover only
  client requests).
- **Report caps are per account.** Many alt accounts can file many reports, push single-reporter
  reports out of a full queue (`queue.maxOpen`) and fill a target's 20-note cap first. Possible
  later: weigh eviction by account age, keep one note per distinct reporter, alert on evictions.
- **Report outcome timing.** An accepted report waits for the note filter and two store writes
  before the "thanks" toast; a capped one answers at once, so a client timing the toast can tell
  them apart. Possible later: send the toast first and run `submit` in a spawned thread.
- **Reports about players who left can be hidden with group roles.** The viewer rule uses only
  ranks Admin knows without a lookup; with `ServerConfig.Admin.groups`, a player's rank is known
  while they are in a server and for `groupCacheSeconds` (600) after. Later, reports about them
  are hidden from staff (fail closed) until they are in a server again; `by = "server"` and the
  console still list them. Games whose staff work the queue later can raise `groupCacheSeconds`.
  Possible later: a budgeted background lookup for hidden targets on the tab.
- **Deep Reports tab pages need paging forward.** A fetch reads at most two index pages, so a
  page far past the staff member's current walk (e.g. jumping to page 40) is empty until the
  pages before it were fetched within 30 s; `queue()` from code reads the whole index.
- **Registered tab cells aren't filtered.** Admin sends a registered tab's string cells as given
  (at most 200 characters); a game must put only keys, numbers or already-filtered text there.
- **`tools/new-project` can only pin a release tag** (`--tag vX.Y.Z`), so an unreleased kit on a
  branch can't be tried in a fresh project, and `single-game-project.md` doesn't say so (seen in
  both dogfoods). Workaround (on the kit page): clone the branch locally, make a local annotated
  tag in that clone only, and pass the clone as `--url` with that `--tag`. Proposed: `--ref
  <branch|sha>` for trying a branch (never for a real game; the lint keeps refusing an untagged
  `studwork/` HEAD for publishing).
- **`tools/make-module` scaffolds `framework = "^1.3.0"`.** A module that uses a v1.7.0+ kit (the
  moderation kit needs `^1.7.0`) must raise it by hand. Proposed: scaffold
  `"^<StudWork.VERSION major.minor>.0"` of the checkout running the tool.
- **`tools/new-project`'s final hint names the game.** It prints new-game's "Next: ... `tools/dev
  <name>`", but in a single-game project the tools take no game name (`tools/dev`). Proposed: a
  single-game hint without the name.
- **Generated specs are `--!nocheck` and testing.md doesn't say why.** `require(script.Parent.ServerConfig)`
  (testing.md's own example) is "Unknown require" in a `--!strict` spec, since specs aren't in the
  sourcemap. Proposed testing.md line: keep `--!nocheck` in specs (the scaffold's convention), or
  cast requires `(require :: any)(...)` in a `--!strict` one. The kit page says this meanwhile.
- **`tools/sync-projects` keeps a deleted `client/` mapping.** After `tools/make-module` and
  deleting the generated `client/` folder, the module's client mapping stays in
  `default.project.json` until removed by hand.
- **"sent" means queued.** A cross-server message waits for the owning server's ping (one per 6 s
  per profile) or its next autosave (minutes); a kick older than `kickMaxAgeSeconds` (600 s) on
  arrival is dropped and audited `"failed"`.
- **Private reasons need TextFilter.** Free text, `privateReason` included, is refused without
  TextFilter, so a game without it bans with presets only.
- **The console is anonymous.** Every kit console command runs as `by = "console"`; the audit
  can't tell who typed it.
- **TextFilter's `maxLength` defaults to 40.** Report notes (`Reports.note.maxLength` 120) and
  announcements (`Admin.announce.maxLength` 200) longer than that are refused by TextFilter (notes
  dropped) until the game raises `config.TextFilter.maxLength`.
- **Studio and the rank rule.** In Studio everyone is staff, so the outranked check is skipped
  for a target whose role comes only from `studioRole`; self-action is still refused, and targets
  listed in `ServerConfig.Admin.users` are checked normally.
- **A pending ban kept in memory only** (`Moderation.note.pendingUnsaved`, store and index both
  down) is retried by that server alone; if it shuts down before the store is back, the ban is
  lost (the audit entry remains).
- **Operational sizes stay in code:** the 200-entry sorted map page, the Reports tab's 20 rows and
  3 detail reads, 100 reporters and 20 notes per report, 50 recently-left players, Admin's
  100-row/12-column/30000-byte `Rows` limits, the sweep's `retentionDays + 7` look-back. Move any
  that games need to tune into config later (additive).
- `Not verified live` additions: which real `BanAsync` errors are transient, real ban modal,
  alt propagation, device block, cross-server latency, real group ranks, voice mute, `CanSend`
  under platform chat, the panel on phones.

## module-reference additions (`docs/framework/module-reference.md`)

- `ctx.services.get(name)` row (currently "(v1.7.0) | an engine service a module may use
  (`BadgeService`, `TextService`, `UserService`, `LocalizationService`, `Players`); ..."): replace
  the list with `BadgeService`, `TextService`, `UserService`, `LocalizationService`, `Players`,
  `GroupService` (v1.8.0), `TextChatService` (v1.8.0), and keep "replaceable by a fake in specs
  (§23.6, §24.1)".
- "Config keys added in v1.8.0": `config.Admin`, `config.Moderation`, `config.Reports` (link the kit
  page); `ServerConfig.Admin` (`users`, `groups`), `ServerConfig.Moderation.admins`,
  `ServerConfig.Moderation.autoSources`, `ServerConfig.Reports.admins` (server-only).

## testing.md (`docs/framework/testing.md`)

The `services = { Name = fake }` row lists what each kit needs. Add after the Notifications
entry: "**Moderation kit** `Players`, `GroupService`, `TextChatService` from the kit's own
`packages/kits/moderation/tests/Fakes.luau` (`Fakes.players()`, `Fakes.groupService()`,
`Fakes.textChatService()`; `Fakes.giveGui(player)` for the panel's `PlayerGui`), plus
`TextService = textService()` when TextFilter is listed. `GroupService` and `TextChatService` are
allowed names from v1.8.0 (module-api §24.1)."

Also document in testing.md (and module-api §19.5) that `StudWork.test.sim.bootGame(path, opts)`
forwards `opts.services` to the sim server, so a game's `Boot.spec.luau` can pass engine fakes:
`F.bootGame("default.project.json", { services = { GroupService = Fakes.groupService() } })`
(needed by any game with `ServerConfig.Admin.groups`: the sim has no GroupService, the lookup
fails and `bootWarnings` is not empty). And correct "kit specs' internal paths are unreachable
from a game": the kit fakes are reachable at `studwork/packages/kits/moderation/tests/Fakes.luau`
(single-game project) or `roblox-core/packages/...` (games repo), required as `(require ::
any)(...)` because luau-lsp resolves string requires relative to the file.

## kit-contract additions (`docs/framework/kit-contract.md`)

```markdown
## Moderation kit (v1.8.0)

### Admin (optional Economy, TextFilter)

- **api:** `can(player, permission) -> boolean` (pure check), `allow(staff, permission) ->
  (boolean, reason?)` (check plus per-staff limits; `"no_permission"`, `"rate_limited"`,
  `"disabled"`), `rankOf(player) -> number`, `rankOfUserId(userId) -> (ok, rank)` (yields; 0 = not
  staff), `limitsOf(staff) -> { maxBanSeconds?, maxMuteSeconds? }`, `roleOf(player) -> string?`,
  `isStaff(player) -> boolean`, `permissions(player) -> { string }` (frozen),
  `onlineStaff() -> { Player }`.
- **extensions (init):** `registerPermission(name, { roles? })`, `registerAction(ActionDef)`,
  `registerTab(TabDef)` (ActionDef/RowAction args `{ preset?, duration?, text?, amount?, note? }`;
  RowAction `presets?`, `notes?`), `registerDataView(id, fn(target) -> { [string]: number |
  boolean | string })` (strings must be declared keys), `onStaffMove(fn(staff, target, "to" |
  "bring"))`, `registerAuditSink(fn(AuditRecord))`, `registerTextFilter(fn(author, text) -> (ok,
  shown | reason))`. Reserved: action ids `teleportTo`, `bring`, `spectate`, `stopSpectate`,
  `announce`, `shutdown`, `grant`, `dataView`; tab ids `players`, `announce`, `data`.
- **signals:** `StaffJoined(player, role)`. **Uses:** Economy (optional, grant action and Data
  balances), TextFilter (optional, free panel text), `ctx.services` (`GroupService`).
- **Added in the hardening pass:** `allow(staff, permission, action?)` (only `ban`/`ban.permanent`
  actions count `bansPerHour`), `rankOfChecked(player | userId) -> number?`,
  `studioRoleOnly(userId) -> boolean`; config `refusedAuditSeconds`.
- **Actions:** `run`, `fetch`, `panelOpen` (net.blink `STUDWORK_ADMIN`; server -> client `Rows`,
  `RunResult`, `Spectate`, `Announce`).
- **Replicated `extra`:** `staff` (staff players only; absent for everyone else). **Save section:** none.
- **Client:** `isStaff()`, `permissions()`, `role()`, `panel()`.

### Moderation (optional Admin, TextFilter)

- **api (actions yield):** `ban(target, opts)`, `unban(userId, opts)`, `history(userId, opts) ->
  (ok, { HistoryEntry } | reason)`, `kick(target, opts)`, `serverBan(target, opts)`,
  `mute(target, opts)`, `unmute(target, opts)`, `isMuted(player) -> (boolean, untilTs?)`,
  `warn(target, opts)`, `punish(target, offense, opts) -> (ok, step | reason, status?)`,
  `report(target, source, severity, details?) -> boolean` (never yields; target a Player or user
  id; true when counted), `audit(opts) -> (ok, entries | reason, more?)` (`opts.page`; a day read
  is bounded by `audit.chunksPerRead`), `record(entry, { by }) -> (ok, reason?)` (whitelisted
  actions); each mutating call takes a required `opts.by: Player | "server" | "console" |
  "system"` (`nil` raises) and returns `(ok, statusOrReason)`. Statuses:
  `"banned"`/`"unbanned"`/`"pending"`; `"done"` (here) or `"sent"` (queued cross-server).
  Reasons: `"no_permission"`, `"outranked"`, `"unknown_rank"`, `"invalid"`, `"no_filter"`,
  `"disabled"`, `"rate_limited"`, `"too_long_for_role"`, `"failed"`, `"unavailable"`.
- **signals:** `Actioned(entry)`, `Muted(player, untilTs?)`, `Banned(userId, seconds)`.
- **Uses:** Admin's api (`allow`, `can`, `rankOf`, `rankOfChecked`, `rankOfUserId`, `limitsOf`) and extensions
  (eight actions, the `audit` tab, the audit sink), TextFilter (staff free text),
  `ctx.data.shared` (`a/<day>/<job8>/<seq>`, `a/<day>/d`, `a/u/<userId>`, `a/s`, `bans/p/<userId>`),
  `ctx.data.sortedMap("pending")`, `ctx.data.messages`, `ctx.services` (`Players`,
  `TextChatService`).
- **Replicated `extra`:** `muted` (own player). **Save section:** `moderation`, not replicated.
- **Client:** `isMuted()`, `onNotice(fn(key, args))`; screen `"ModerationNotice"`; event `Notice`
  (net.blink `STUDWORK_MODERATION`).

### Reports (optional Admin, Moderation, TextFilter)

- **api:** `submit(reporter, targetUserId, category, note?) -> (ok, reason?)` (yields),
  `queue(opts) -> (ok, { ReportSummary } | reason)`, `detail(reportId, opts) -> (ok, Report |
  reason)`, `claim(reportId, opts)`, `resolve(reportId, resolution, opts)`,
  `registerContext(fn(targetUserId, target?) -> table?)` (also an extension).
- **signals:** `Submitted(reportId, targetUserId, category)`, `Resolved(reportId, resolution)` (never
  a reporter id).
- **Uses:** Admin (`registerTab` with `claim`/`resolve` row actions, `allow`, `can`, ranks for the
  viewer rules), Moderation (`report` for autoAction, `record` on claim and resolve), TextFilter
  (notes), `ctx.data.shared` (`r/t/<userId>`), `ctx.data.sortedMap("queue")`. Reporter ids only for
  `reports.reporters`.
- **Actions:** `submit` (net.blink `STUDWORK_REPORTS`).
- **Replicated `extra`:** `recent` (setAll, `{ userId, name }`). **Save section:**
  `reports`, not replicated.
- **Client:** `open(targetUserId?)`, `recent()`, `read`; screen `"Report"`.
```

Also update the page's intro count ("The fifteen built-in kit modules" -> eighteen) and its kit
page list.

## module-api §24 addition

```markdown
## 24. Additions in v1.8.0

### 24.1 `ctx.services.get`: `GroupService` and `TextChatService` (added in v1.8.0: the moderation kit resolves staff roles from groups and mutes text chat, and Lune specs must fake both)

- `Services.ALLOWED` gains `GroupService` and `TextChatService` (§23.6 said later additions are
  additive). The allowed names are now `BadgeService`, `TextService`, `UserService`,
  `LocalizationService`, `Players`, `GroupService`, `TextChatService`. Nothing else changes: the
  refused list, the fake/stub rules and the live `game:GetService` path are as in §23.6. In §23.6's
  "Allowed names" bullet, add "(v1.8.0 adds `GroupService` and `TextChatService`, §24.1)".
- Why `GroupService`: `Player:GetRankInGroup`, `GetRankInGroupAsync` and `GetRoleInGroupAsync` are
  deprecated in favour of `GroupService:GetRolesInGroupAsync(userId, groupId)`
  (https://create.roblox.com/docs/reference/engine/classes/Player#GetRankInGroupAsync).
- Why `TextChatService`: a server mute sets `TextSource.CanSend = false` on the muted user's text
  sources (https://create.roblox.com/docs/reference/engine/classes/TextSource).
- Fakes for these live with the kit that uses them (`packages/kits/moderation/tests/Fakes.luau`);
  `StudWork.test.fakes` gains nothing.

### 24.2 Proposed, not done: `ctx.framework.isAdmin(player)` and a console permission hook

- `ctx.framework.isAdmin(player) -> boolean` would expose the framework's `ServerConfig.admins`
  rule (Studio: everyone) read-only, so a module with Admin off needn't keep its own
  `ServerConfig.<Module>.admins` list.
- A console permission hook (e.g. `ctx.console.setAuthorizer(fn(player, command) -> boolean)`, one
  module at most) would let Admin's roles govern the framework's own console commands.
- Neither is in this release; the kit documents its fallbacks instead.

### 24.3 Proposed, not done: `ctx.data.shared.get(key)`

- `ctx.data.shared` has only `update`; a read is `update(key, function(old) return old end)`, a full
  DataStore write (and `return nil` deletes the key). A `get(key) -> (ok, value?)` backed by
  `GetAsync` (cached briefly, budgeted like sorted maps) would let a module read a shared key
  without writing it.
- The moderation kit works around it with sorted map indexes and rate-limited audit reads; with
  `get` it could drop those writes. Not in this release.
```

## `--modules` lines (`tools/lune/KitModules.luau`) and the NewGame spec

`KitModules.ORDER` (the template's boot order) is **not** changed on the branch: the manifest
appends kit modules that `ORDER` doesn't list after it, alphabetically, so `Admin`, `Moderation`,
`Reports` already come after `Plot` (Admin first, so the other two find it registered) and
`tools/new-game --modules` / `tools/new-project --modules` accept them. When the template lists
them (below), add the same three names to `ORDER` after `"Plot"`.

**Changed on the branch (shared spec):** `tools/lune/NewGame.spec.luau`, "the kit manifest comes
from the kit definitions", asserted `#Modules.ORDER == 15`. Any new kit module breaks that count,
so it now asserts `18` and additionally pins `ORDER[15] == "Plot"` and `ORDER[16..18] == { "Admin",
"Moderation", "Reports" }`. The assertion is stricter, not weaker (it checks the order of the new
entries too); the maintainer should keep it in the merge.

## Sandbox and template wiring

`templates/new-game/src/shared/Config/init.luau` and `examples/sandbox/src/shared/Config/init.luau`,
after the Plot line:

```lua
		require(Modules:WaitForChild("Admin"):WaitForChild("module")), -- staff roles, permissions and the staff panel (ServerConfig.Admin)
		require(Modules:WaitForChild("Moderation"):WaitForChild("module")), -- bans, kicks, mutes, warnings, ladders, audit log
		require(Modules:WaitForChild("Reports"):WaitForChild("module")), -- player reports and the staff queue
```

`ServerConfig.luau` (template and sandbox):

```lua
	-- Staff (moderation kit, docs/framework/kits/moderation.md). Live: nobody is staff unless listed.
	Admin = {
		users = {} :: { [number]: string }, -- [userId] = "owner" | "admin" | "moderator" | "helper"
		groups = {} :: { any }, -- { { groupId = 0, roles = { { roleId = 0, role = "moderator" } } } }
	},
```

`Balance.luau`: no change needed (defaults); the sandbox may set `Moderation.auto.sources` for a
demo source. `GameConfig.strings`: `["Moderation.ban.appeal"] = "Appeal on our group page."`.
Then run `tools/sync-projects` (generated Modules entries in every `*.project.json`).

Docs indexes: `docs/README.md` (kit table: a Moderation row linking
`framework/kits/moderation.md`) and `docs/framework/README.md` (the module pages row).
`docs/manual-qa.md`: a "New in v1.8.0" list from the kit page's "Not verifiable offline".

## Guardrails (`docs/framework/guardrails.md`, `tools/lune/guardrails.luau`)

Placeholder, optional, not built in this round:

| Check | Catches |
|---|---|
| `moderation` (proposed) | `:Kick(` and `BanAsync`/`UnbanAsync` in server code outside the Moderation module, in games, examples and kits (not specs), so every removal is permission-checked and audited. `-- guard: allow moderation` with a reason for a genuine case (a game's own anti-exploit kick before data loads). Self-test plants: `player:Kick("x")`, `Players:BanAsync({...})`, `game:GetService("Players"):UnbanAsync(...)`; must pass inside `packages/kits/moderation/Moderation/` and on a guarded line |

Admin's shutdown action and Moderation itself call `Kick`; if the check is built, Admin's two
kick lines need a guard line (or the check exempts `packages/kits/moderation/`).

## Framework and shared files touched on the branch

- `packages/framework/server/Services.luau`: `GroupService = true`, `TextChatService = true` in
  `Services.ALLOWED`; `packages/framework/test/ServicesGet.spec.luau`: fakes for both names and the
  longer allowed-list message (extended, not weakened). Why: §24.1. No other framework or UI kit
  file changes (`ctx.data.shared.get`, §24.3, is a proposal only).
- `tools/lune/NewGame.spec.luau`: the kit module count 15 -> 18 (see the `--modules` section).
- Generated by `tools/sync-projects` (Modules entries for Admin, Moderation, Reports):
  `examples/modules/session-leaderboard/tests/fixture-game/default.project.json`,
  `examples/overrides/ov-a..ov-f/default.project.json`, `examples/sandbox/default.project.json`,
  `examples/sandbox/foundation-only.project.json`, `templates/new-game/default.project.json`.

## Open notes

Settled by the design's addenda and now in the code and on the page: success statuses
(`"done"`/`"sent"`, `"banned"`/`"unbanned"`/`"pending"`, `punish`'s returns), per-staff limits
through `Admin.allow` counted once, `limitsOf`, the recently-left key (`recent`), RemoteScopes, the
reduce-motion rule, `audit.maxPerDay` and `Reports.retentionDays` dropped, role `maxMuteSeconds`
defaults (helper 3600, moderator 86400), `grant = { max, currencies }`, the sweep timing, `queue()`
returning summaries plus `detail()`, the store-down pending case (`"pending"`, `pendingUnsaved`),
absolute messaged mute end, trusted-actor text, the Studio rank skip, refused staff audits.

Fixed in the code since the first draft of this list (no longer open): Admin's optional
TextFilter (Addendum F), the panel's resolve note, the double-counted Audit tab fetch, the total
Studio rank skip, Admin's fixed-hour refused throttle (now `config.Admin.refusedAuditSeconds`),
the grant amount in the audit, `Admin.result.claimed`; and the final review's findings (unknown
ranks, bounded audit reads, role caps on delivery, retention, the Reports tab's group budget,
reports past 200, the submit/resolve race, bans-only `bansPerHour`, claimer-only resolve, spectate
cleanup, flush races).

Still open (for the maintainer; the code is what the page describes):

- **`Admin.result.not_found`** reads "That player isn't in this server" also for a missing report
  (a Reports row action); a neutral wording or a Reports-specific key would read better.
- **Known issues above that have a possible later fix:** report outcome timing, alt-account
  gaming of report caps, per-server staff limits, Admin-off limits, untouched report and audit
  index keys, `ctx.data.shared.get` (§24.3).
- **Tooling seen in the dogfoods:** `tools/new-project --ref`, its single-game final hint,
  `tools/make-module`'s `"^1.3.0"`, the stale `client/` mapping kept by `tools/sync-projects` and the
  spec strictness note for testing.md (known issues above); all framework tools or shared docs, not
  kit code.
