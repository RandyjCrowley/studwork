# Social kit: TextFilter

One way to filter any player-entered text (a pet name, a plot sign, a message board) by who will
see it: everyone, only friends, or only the author. Code: `packages/kits/social/TextFilter/`
(`module.luau`, `server/`; no client part; Rojo `ReplicatedStorage.Modules.TextFilter`,
`ServerScriptService.Modules.TextFilter`). Added in v1.7.0 (design:
[module-api.md §23](../module-api.md#23-additions-in-v170)). Entries marked **(contract)** are part
of the cross-module surface in [kit-contract.md](../kit-contract.md).

```lua
local TextFilter = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TextFilter"):WaitForChild("module"))
```

**Unfiltered player text is never shown to another player, and never handed to a caller in a form
it could replicate.** Roblox requires every piece of player-entered text that a user can see to
pass `TextService:FilterStringAsync` and the `TextFilterResult` method for that audience; an
experience that doesn't is removed until it does. This module is the one path; the `textfilter`
lint check (below) flags game code that skips it. The original text stays inside this module's own
server-only save section: nothing the API returns contains it.

## Quick start

In `GameConfig.modules` add `TextFilter`. Filter on the server, from an action handler (it yields),
and show only what comes back, never the text the player typed.

```lua
-- game module action (server)
local ok, stored = ctx.deps[TextFilter].store(player, name, "public")   -- or filter(...) for text you don't keep
if ok then ctx.data.update(player, function(s) s.petNames[uid] = stored end) end
-- later, for any viewer: ctx.deps[TextFilter].shown(stored)
-- spec (mirrored by KitQuickStarts.spec.luau): the fake replaces "badword"; policy allows public text
local h = StudWork.test.harness({ modules = { TextFilter }, policy = { [1] = { IsContentSharingAllowed = true } },
	services = { TextService = StudWork.test.fakes.textService({ replace = { badword = true } }) } })
local ok, result = h:use(TextFilter).filter(h:addPlayer({ userId = 1 }), "a badword", "public")
```

## Contexts

| Context | Who may see it | Roblox calls | Text filter context |
|---|---|---|---|
| `"public"` | everyone, including players who join after the author left (a sign, a plot name) | `FilterStringAsync(text, authorId, PublicChat)` then `GetNonChatStringForBroadcastAsync()` | `Enum.TextFilterContext.PublicChat` |
| `"friends"` | the author and the author's friends in the server | `FilterStringAsync(text, authorId, PrivateChat)` then `GetNonChatStringForUserAsync(viewerId)` per viewer | `PrivateChat` |
| `"private"` | only the author (a pet name only its owner sees) | the same, for the author's own id | `PrivateChat` |

The `TextFilterContext` is a hint to Roblox: it doesn't change the filtered result. What decides
who may see the text is the `TextFilterResult` method, which is what the context picks.

Text that only the author sees on their own client while typing needs no filter; anything sent
to the server and shown back (even to the author alone) goes through `"private"`.

## Config (`config.TextFilter`)

| Key | Default | Meaning |
|---|---|---|
| `maxLength` | `40` | longer input is refused (`"too_long"`); 1..200 |
| `trim` | `true` | strip leading/trailing whitespace and collapse runs of spaces before filtering |
| `cache.maxEntries` | `500` | cached **re-display** results per server (least recently used are dropped); a new submission is always filtered fresh |
| `cache.seconds` | `600` | a cached re-display result is re-filtered after this long; `0` turns the cache off. Under 60, `shown`'s re-filters count against the `textFor` bucket (below), so it stays bounded |
| `perPlayerPerMinute` | `20` | filter calls one author's text can cause per minute, in two separate buckets: the author's submissions (`filter`, `store`; over the limit: `"rate_limited"`), and `textFor` calls that miss the cache (over the limit: nil, so the caller shows the fallback). What viewers re-display never spends the author's submissions. A `textFor` served from the cache costs nothing; `shown` isn't counted while `cache.seconds` is 60 or more (see `shown`) |
| `originals.max` | `100` | originals kept per author in this module's save section; the oldest is dropped first (its records then show `shown` only, below) |
| `shownMaxDays` | `7` | a `"public"` record's saved broadcast string is shown while the author is away for at most this many days after it was filtered; after that, nil until the author is in a server again (a week: a string filtered under older rules is not shown for long) |
| `fallbackKey` | `"TextFilter.hidden"` | the string key ([localization](localization.md)) callers show instead of text that can't be shown (English default: `"..."`) |
| `respectContentSharing` | `true` | an author whose `PolicyService` `IsContentSharingAllowed` is false (or unknown) can't publish `"public"` or `"friends"` text (`"policy"`); `"private"` still works |

## API (server)

All calls that filter **yield** (they call Roblox). Call them from an action handler or a spawned
thread, never inside `ctx.tx`.

- `filter(author, text, context) -> (ok, result | reason)`: a **submission**: validates
  (`maxLength`, control characters stripped, empty refused) and calls `FilterStringAsync` once,
  never from the cache (Roblox asks for one call per submission). **(contract)**
  `result` is a `Filtered` handle:
  - `result.public -> string?`: the broadcast string (`"public"` only).
  - `result.forViewer(viewer) -> string?`: the string for one viewer, or nil when that viewer
    may not see it (not the author / not a friend, or the viewer left). Yields the first time per
    viewer, then cached. For `"public"` it is the broadcast string for anyone in the server.
  - `result.context`, `result.author` (user id). The original text is **not** exposed.
- `textFor(viewer, author, text, context) -> string?`: re-display of text the author already
  submitted (filtered then): filters through the re-display cache and returns what `viewer` may
  see, or nil. A submission's result seeds the cache, so showing it right after costs no call.
  A cache miss is one `FilterStringAsync` and counts against the author's re-display bucket
  (`perPlayerPerMinute`, kept apart from the author's submissions; over it: nil), so text a client
  sends straight to `textFor` is bounded, and viewers can't use up the author's own submissions.
  New player text still belongs in `filter` or `store`. **(contract)**
- `store(author, text, context) -> (ok, Stored | reason)`: a submission that is kept: filters,
  saves the original in **this module's** section of the author's save (`originals[id]`, never
  replicated), and returns `Stored = { id, author, context, at, shown? }`. `shown` is the broadcast
  string (`"public"` only) for display while the author is offline. The record holds no original
  text, so it is safe to keep in any section. **(contract)**
- `shown(stored, viewer?) -> string?`: what to display from a `Stored` record: re-filtered from the
  original when the author is in the server (the result is held per record for `cache.seconds`,
  apart from the re-display cache, so a record is re-filtered at most once per `cache.seconds` and
  nothing is rate-limited: the original was a submission, counted when stored; with `cache.seconds`
  under 60 that hold is no bound, so a re-filter then counts against the author's `textFor`
  bucket, and over it the record shows as if the author were away); otherwise
  `stored.shown` for `"public"` while it is younger than `shownMaxDays`, and nil for `"friends"` and
  `"private"` or an older record. Without a `viewer` only `"public"` text has a string (the
  broadcast one). **(contract)**
- `release(author, stored)`: drops the original (the caller deleted the pet, cleared the sign).
  Doesn't yield. **(contract)**
- Reasons: `"empty"`, `"too_long"`, `"rate_limited"`, `"policy"`, `"author_offline"` (Roblox
  can only filter for an author who is in this server), `"filter_failed"` (Roblox errored; the
  text must not be shown).

Friendship for `"friends"` is `player:IsFriendsWithAsync`, cached per pair for the session (the
same rule the Friends module uses); the Friends module isn't required.

**Privacy:** player text (original or filtered) is never logged and never sent to analytics; the
module's warnings and analytics carry the author id, the context and the reason only.

## Typical use

```lua
-- a game module's action: rename a pet (shown to everyone near the plot)
actions = {
	renamePet = { limit = { rate = 1, burst = 2 }, handler = function(player, uid: string, name: string)
		local ok, stored = ctx.deps[TextFilter].store(player, name, "public")
		if not ok then
			ctx.net.feedback(player, "toast", ctx.text.format(player, "TextFilter.refused"))
			return
		end
		ctx.data.update(player, function(s) s.petNames[uid] = stored end)
		-- the billboard shows ctx.deps[TextFilter].shown(stored), never `name` and never `stored` itself
	end },
}
```

## Save data and replication

Section `textfilter`, version 1: `{ originals = { [tostring(id)] = { t = text, c = context, at } }, nextId = 1 }`
(string keys, so the save stays a dictionary),
`replicate = false`. Only this module reads it, and only on the server where the author is.
Callers keep `Stored` records in their own sections. The in-memory re-display cache is not saved.

## The `textfilter` lint check (new)

Best-effort, in game code, examples and kits (server files): it flags player text that reaches a
player (or a store other players read) without passing TextFilter.

- **Sources:** every parameter of an action handler after the player, `...` included, unless it is
  annotated with only `number`/`boolean` types: a value from the wire is untrusted whatever else it
  is annotated (`string`, `any`, `unknown`, a table type). Handlers: `handler = ...`, an entry of an
  `actions = { ... }` table, or `actions.<name> = ...`, where the value is an inline function or the
  name of a function defined in the same file (`local function onRename(player, name)` then
  `handler = onRename`; a dotted name, `function M.onRename(...)` or `M.onRename = function(...)`
  then `handler = M.onRename`), or either wrapped in a call (`handler = guard(onRename)`,
  `handler = Util.wrap(M.onRename, 2)`, `handler = guard(function(player, name) ... end)`): every
  argument of the call that is a function, or names one in the same file, is scanned as a handler.
- **Filter records:** the values `filter` and `store` return (`Filtered`, `Stored`) are their own
  class: passing the **whole** value to a sink is a finding (use `result.public`,
  `result.forViewer(...)` or `TextFilter.shown(stored)`), so the display rules (viewer, age) apply.
- **Sinks:** `ctx.replicate.setAll(...)`; `ctx.replicate.set(<any player>, ...)` and
  `ctx.net.fire(<any player>, ...)`, **including the handler's own player** (text shown back to its
  author goes through `"private"`); `ctx.net.fireAll(...)`; `ctx.data.messages.send`; a `Mail`
  `send`; `ctx.data.shared.update(...)` (values other players' servers read); writes on a store
  from `ctx.data.sortedMap(...)` / `ctx.data.ordered(...)` (`set`, `update`, `increment`, directly or
  through a local assigned from one); `Notifications` `send`/`schedule` params; any `.Text =`,
  `.Name =`, `:SetAttribute(` or a `Text`/`Name` prop in an `Instance.new` table.
- **Clean values:** only what a TextFilter call returns (`result.public`, `result.forViewer(...)`,
  `textFor(...)`, `shown(...)`); those are new names that carry no taint. Passing a name to
  `filter`, `textFor` or `store` never clears it: filtering the text and then sending the original
  anyway is exactly the mistake this check exists for.
- **Finding:** a sink whose arguments mention a source identifier directly (or a local assigned
  from one by plain assignment, `..`, `string.sub`/`format`/`lower`/`upper`) in the same function,
  before or after any TextFilter call; or a sink given a whole filter record. Messages:
  `player text '<name>' reaches <sink> without TextFilter (docs/framework/kits/textfilter.md)` and
  `filter record '<name>' reaches <sink> whole: pass TextFilter.shown(...) or .public (docs/framework/kits/textfilter.md)`.
- **Limits:** it follows names only within one function and one file (a handler that hands the
  text to another function, even a local helper that holds the sink, or a handler defined in
  another file, isn't followed); a method handler (`function M:onRename`), a handler looked up
  from a table (`handlers[name]`) or one returned by a call defined elsewhere isn't resolved;
  reassigning a param to a filtered value (`name = r.public`) doesn't clear it (use a new name);
  text that travels through
  tables, other modules or saves isn't followed (the author's own save isn't a sink: it never
  holds another player's text unless a later read sends it on, which a sink in that code catches).
  `-- guard: allow textfilter` at the end of the sink's line, with a reason on the line above, for
  genuine non-text strings (an enum value checked against a list).
- **Self-test** plants (each must fail): an action param into `replicate.setAll`, into `.Text =`,
  through a `..` concatenation into `fireAll`, back to the handler's own player with
  `ctx.net.fire(player, ...)`, into `ctx.replicate.set(other, ...)`, into `ctx.data.shared.update`,
  into a sorted map `set`, into `Notifications` `send` params, a whole `Stored` record into
  `setAll("sign", stored)`, the original sent after `filter` (`"public"` into `setAll`, `"private"`
  into `fireAll`) and after `store`, a named local handler, a `local f = function` actions entry,
  `actions.x = f`, a dotted handler (`handler = M.f`, `{ x = T.f }` with `T.f = function`), a
  wrapped handler (`guard(f)`, `Util.wrap(M.f, 2)`, `guard(function ... end)`), and params typed
  `any`, a table, a union with `string`, and `...`. Must pass: the same flows after `store(...)`
  with `TextFilter.shown(stored)`, after `textFor(...)`, a named handler that sends only
  `r.public` (also dotted and wrapped), a wrapper's other arguments, `number`/`boolean` params,
  and a guarded non-text param.

## Override levels

1. Use the defaults: list the module and call it.
2. Config: lengths, cache, rate, originals kept, `shownMaxDays`, policy behaviour.
3. Replace a piece: your own fallback text key.
4. Switch it off: leave it out of `modules`. Then any player text your game shows to others has no
   filter at all; the lint check still flags it.

## Failure behaviour

| Situation | Behaviour |
|---|---|
| `FilterStringAsync` errors (Roblox already retried internally) | `(false, "filter_failed")`; never retried by the kit; caller shows the fallback |
| `GetNonChatStringForUserAsync` errors for a viewer | that viewer gets nil (show the fallback) |
| Author left | `filter`/`store` refuse; `shown` returns the stored broadcast string (public, within `shownMaxDays`) or nil |
| Original dropped (over `originals.max` or released) | `shown` behaves as if the author were away |
| Policy unknown | `"public"`/`"friends"` refused until known (fail closed) |

## Tests (mocked)

`StudWork.test.fakes.textService({ replace = { ["badword"] = "#######" }, failNext = n,
offline = { userIds } })` as `harness({ services = { TextService = fake } })`; the fake's results
offer the broadcast and per-user methods and record calls. Specs: each context and who gets nil;
two submissions of the same text make two filter calls, while re-display is cached (expiry
re-filters); `maxLength`, trimming, control characters; per-author rate limit (re-display by
viewers, `textFor` or `shown`, never spends it); `shown` re-filters a record at most once per
`cache.seconds` even past `cache.maxEntries`; policy refusal
(`harness({ policy = ... })` extended with `IsContentSharingAllowed`); author offline;
`filter_failed` never returns the original; a `Stored` record contains no original text; the
original never replicates (the section isn't in `extra` or `data` state); `store`/`shown` round
trip across a rejoin; `shownMaxDays`; `originals.max` drops the oldest; `release`. The guardrail
self-test covers the lint check.

## Not verifiable offline

Roblox's actual filter output, its age-based differences between viewers, and the per-user
filtering latency right after a join. Live checklist: [manual-qa.md](../../manual-qa.md), "New in v1.7.0".
