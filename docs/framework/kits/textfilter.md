# Social kit: TextFilter

One way to filter any player-entered text (a pet name, a plot sign, a message board) by who will
see it: everyone, only friends, or only the author. Results are cached per string and context.
Code: `packages/kits/social/TextFilter/` (`module.luau`, `server/`; no client part; Rojo
`ReplicatedStorage.Modules.TextFilter`, `ServerScriptService.Modules.TextFilter`). Added in v1.7.0
(design: [module-api.md §23](../module-api.md#23-additions-in-v170)). Entries marked
**(contract)** are part of the cross-module surface in [kit-contract.md](../kit-contract.md).

```lua
local TextFilter = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TextFilter"):WaitForChild("module"))
```

**Unfiltered player text is never shown to another player.** Roblox requires every piece of
player-entered text that another user can see to pass `TextService:FilterStringAsync` and the
`TextFilterResult` method for that audience; an experience that doesn't is removed until it does.
This module is the one path; the `textfilter` lint check (below) flags game code that skips it.

## Contexts

| Context | Who may see it | Roblox calls | Text filter context |
|---|---|---|---|
| `"public"` | everyone, including players who join after the author left (a sign, a plot name) | `FilterStringAsync(text, authorId, PublicChat)` then `GetNonChatStringForBroadcastAsync()` | `Enum.TextFilterContext.PublicChat` |
| `"friends"` | the author and the author's friends in the server | `FilterStringAsync(text, authorId, PrivateChat)` then `GetNonChatStringForUserAsync(viewerId)` per viewer | `PrivateChat` |
| `"private"` | only the author (a pet name only its owner sees) | the same, for the author's own id | `PrivateChat` |

Text that only the author sees on their own client while typing needs no filter; anything sent
to the server and shown back (even to the author alone) goes through `"private"`.

## Config (`config.TextFilter`)

| Key | Default | Meaning |
|---|---|---|
| `maxLength` | `40` | longer input is refused (`"too_long"`); 1..200 |
| `trim` | `true` | strip leading/trailing whitespace and collapse runs of spaces before filtering |
| `cache.maxEntries` | `500` | cached filter results per server (least recently used are dropped) |
| `cache.seconds` | `600` | a cached result is re-filtered after this long |
| `perPlayerPerMinute` | `20` | filter calls one author can cause per minute (an over-limit call returns `"rate_limited"`) |
| `fallbackKey` | `"TextFilter.hidden"` | the string key ([localization](localization.md)) callers show instead of text that can't be shown (English default: `"..."`) |
| `respectContentSharing` | `true` | an author whose `PolicyService` `IsContentSharingAllowed` is false (or unknown) can't publish `"public"` or `"friends"` text (`"policy"`); `"private"` still works |

## API (server)

All calls that filter **yield** (they call Roblox). Call them from an action handler or a spawned
thread, never inside `ctx.tx`.

- `filter(author, text, context) -> (ok, result | reason)`: validates (`maxLength`, control
  characters stripped, empty refused), filters, caches. **(contract)**
  `result` is a `Filtered` handle:
  - `result.public -> string?`: the broadcast string (`"public"` only).
  - `result.forViewer(viewer) -> string?`: the string for one viewer, or nil when that viewer
    may not see it (not the author / not a friend, or the viewer left). Yields the first time per
    viewer, then cached.
  - `result.context`, `result.author` (user id), `result.raw` is **not** exposed.
- `textFor(viewer, author, text, context) -> string?`: one-shot for display: filters (cached) and
  returns what `viewer` may see, or nil. **(contract)**
- `store(author, text, context) -> (ok, Stored | reason)`: filters and returns a save-ready
  record `{ text = <input>, shown = <broadcast string or nil>, context, at }` for the caller's
  own section. `shown` is what to display while the author is offline (`"public"` only); the
  original stays in the author's own save so it can be re-filtered later. **(contract)**
- `shown(stored, viewer?) -> string?`: what to display from a `Stored` record: re-filtered (cached)
  when the author is in the server, otherwise `stored.shown` for `"public"`, nil for `"friends"`
  and `"private"` while the author is away. **(contract)**
- Reasons: `"empty"`, `"too_long"`, `"rate_limited"`, `"policy"`, `"author_offline"` (Roblox
  can only filter for an author who is in this server), `"filter_failed"` (Roblox errored; the
  text must not be shown).

Friendship for `"friends"` is `player:IsFriendsWithAsync`, cached per pair for the session (the
same rule the Friends module uses); the Friends module isn't required.

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
		-- the billboard shows TextFilter.shown(stored), never `name`
	end },
}
```

## Save data and replication

None: the module keeps only its in-memory cache. Callers keep `Stored` records in their own
sections.

## The `textfilter` lint check (new)

Best-effort, in game code, examples and kits (server files): it flags a string that came from a
client and reaches another player without passing TextFilter.

- **Sources:** parameters of an action handler (`actions = { x = function(player, a, b)` or
  `handler = function(player, ...)`) annotated `string` or unannotated.
- **Sinks:** `ctx.replicate.setAll(...)`, `ctx.net.fireAll(...)`, `ctx.net.fire(other, ...)`
  where `other` isn't the handler's `player`, `ctx.data.messages.send`, a `Mail` `send`, any
  `.Text =`, `.Name =`, `:SetAttribute(` or a `Text`/`Name` prop in an `Instance.new` table.
- **Finding:** a sink whose arguments mention a source identifier directly (or a local assigned
  from one by plain assignment, `..`, `string.sub`/`format`/`lower`/`upper`) in the same function,
  when that identifier hasn't been passed to a TextFilter call (`filter`, `textFor`, `store`) on an
  earlier line of the function. Message:
  `player text '<name>' reaches <sink> without TextFilter (docs/framework/kits/textfilter.md)`.
- **Limits:** it follows names only within one function and one file; text that travels through
  tables, other modules or saves isn't followed (the save itself is the author's own and isn't a
  sink). `-- guard: allow textfilter` with a reason on the line above for genuine non-text strings
  (an enum value checked against a list). The self-test plants: an action param into
  `replicate.setAll`, into `.Text =` and through a `..` concatenation (each must fail), and the
  same flows after `store(...)` / `textFor(...)` (must pass).

## Override levels

1. Use the defaults: list the module and call it.
2. Config: lengths, cache, rate, policy behaviour.
3. Replace a piece: your own fallback text key.
4. Switch it off: leave it out of `modules`. Then any player text your game shows to others has no
   filter at all; the lint check still flags it.

## Failure behaviour

| Situation | Behaviour |
|---|---|
| `FilterStringAsync` errors (Roblox already retried internally) | `(false, "filter_failed")`; never retried by the kit; caller shows the fallback |
| `GetNonChatStringForUserAsync` errors for a viewer | that viewer gets nil (show the fallback) |
| Author left | `filter` refuses; `shown` returns the stored broadcast string or nil |
| Policy unknown | `"public"`/`"friends"` refused until known (fail closed) |

## Tests (mocked)

`StudWork.test.fakes.textService({ replace = { ["badword"] = "#######" }, failNext = n,
offline = { userIds } })` as `harness({ services = { TextService = fake } })`; the fake's results
offer the broadcast and per-user methods and record calls. Specs: each context and who gets nil;
the cache (the second call makes no fake call; expiry re-filters); `maxLength`, trimming, control
characters; per-author rate limit; policy refusal (`harness({ policy = ... })` extended with
`IsContentSharingAllowed`); author offline; `filter_failed` never returns the raw text;
`store`/`shown` round trip across a rejoin. The guardrail self-test covers the lint check.

## Not verifiable offline

Roblox's actual filter output, its age-based differences between viewers, and the per-user
filtering latency right after a join. Live checklist in the round report.
