# Guardrails: what you can't turn off, and why

Some opinions protect players, your revenue and your standing with Roblox. They are not config
([philosophy §4](../philosophy.md#4-guardrails-you-cant-turn-off-by-accident)). This page says
what each one guarantees, how it is enforced, and, honestly, where enforcement stops and only
guidance is left.

## The server is authoritative

- Clients only send requests. Every module action is routed by the framework: rate-limited per
  player per action (default 4/s, burst 8), dropped when the player has left, held until the
  player's data has loaded, and run in `pcall`.
- Blink checks wire types. **Your handler still checks ownership, ranges and rules.**
- Raw `RemoteEvent`, `RemoteFunction`, `UnreliableRemoteEvent`, `OnServerEvent`/`OnServerInvoke`
  and Blink `.On(` in server game code are refused by the `remotes` lint guardrail.

## Purchases are safe to retry

- The framework owns `MarketplaceService.ProcessReceipt`. A purchase handler (`ctx.shop.onProduct`)
  gets a `tx`; the grant and the receipt record commit in one save, and `PurchaseGranted` is
  returned only after that save. An error or `tx.retryLater()` grants nothing and Roblox retries.
- If the buyer leaves before the save is confirmed, the framework makes one more confirmed save
  before releasing them; `tx.after` effects run only after confirmation.
- The `purchases` lint guardrail refuses any other `ProcessReceipt =`, any
  `Prompt*PurchaseFinished` use, and `DataStoreService`/`ProfileStore` outside framework Data.
- The Shop claims `ProcessReceipt` as the very last boot step, after every module's `init` and
  `start`, so no module code that runs at boot can replace it.
- **Limit ([known issues](../known-issues.md)): on a live server a replacement can't be detected at runtime.**
  `ProcessReceipt` is a write-only callback in the engine, so it can't be read back to compare. The
  runtime check (warn naming the source, `ProcessReceiptHijacked` analytics, reclaim) works with
  the fake platform in tests; live, `receiptCheck().status` reports it unavailable. Enforcement
  there is the lint guardrail plus claiming last. Never assign `ProcessReceipt` yourself, and
  patch any vendored package that does.

## Paid-random compliance

Any random outcome bought with Robux, or with a currency bought with Robux, has its full odds
disclosed and is policy-checked per player.

What is **enforced** by the framework, for every module including third-party ones:

- A registered random source (`ctx.compliance.registerRandomSource`) gives outcomes only through
  `ctx.compliance.roll` / `spendForRoll`, which do the policy check, the luck rule and the sample
  in one call. There is no "forgot to call the check" path.
- Every purchase transaction is marked paid by the Shop; items granted in it get a `paid:` tag,
  and items from a paid-currency roll get `paidcur:`. The tag is derived, not passed in.
- Currencies in `GameConfig.compliance.paidCurrencies` can only be spent for a roll through
  `spendForRoll`, which spends and rolls in the same transaction. Economy's `txApi.spend` of such a
  currency errors, and so does its `api.spend`. There is no "free roll" escape: a
  genuinely free reward calls `roll`.
- Every currency in `GameConfig.compliance.paidCurrencies` has a spender (since v1.3.1): once every module has run `init` and `start`, boot fails closed if a listed currency
  has no spender registered through `ctx.compliance.registerCurrencySpender` ("compliance.paidCurrencies
  lists 'Gems', but no enabled module registered a spender for it ..."). A paid currency can no
  longer be listed while `spendForRoll` / `spendPaid` would error on every call because its owner
  isn't enabled. What this checks is that *a* spender exists, one per currency (a second
  registration errors); not which module registered it, nor that the spender debits the right
  balance ([module-api.md §19.10](module-api.md#1910-every-paid-currency-has-a-spender-at-boot-added-in-v131)).
- Luck on a paid roll is refused unless the source discloses luck and that player was sent exactly
  those odds (`ctx.replicate.sent`).
- Unknown policy: retried later inside a purchase, refused outside. Restricted: refused with
  `"restricted"`; grant a fixed non-random fallback.

What can **only be guided**:

- A module that keeps a paid currency's balance in its own data section can still debit it
  directly, without going through its registered spender / `spendForRoll` (Economy's own
  `txApi.spend` refuses, but the framework can't see a third-party module writing its own section).
  The boot check only proves a spender exists; the rest stays guided (docs, code review).

- Module code can still invent randomness outside these APIs (`math.random`, `Random.new`) and
  never register a source. The framework can't see that. The docs and the generator templates
  steer authors to Compliance (a lint heuristic for `math.random`/`Random.new` near a currency or
  item grant is not built yet); code review is the backstop.
- The client is trusted to *show* the disclosed odds before a prompt (`UI.OddsTable`) and to hide
  prompts from restricted players. The server refuses the restricted player's paid roll regardless.

## Saves can't be overwritten

- A save that fails to load or to migrate never gets defaults written over it: nothing is saved,
  and the player gets a friendly kick ("Your save couldn't be loaded safely, so nothing was
  changed. Please rejoin in a moment.") with their data kept.
- A save written by newer code (a section version above the module's) is left untouched.
- A stolen session (the same save opened in another server) kicks at once, and every later save
  path on the old server writes nothing.
- A disabled module's section is carried through saves untouched.

## Modules stay in their own data

- `ctx.data` and `ctx.section(tx)` reach only the calling module's own section; `tx` is a sealed
  handle with no `data` field. Everything else goes through other modules' public APIs.
- Read views (`ctx.data.get`, kit `get`/`list`) are frozen in every environment, so an in-place
  write can't skip migrations or replication.
- One module per save-section key, checked at boot among enabled modules and against
  `_framework._owners` on every load (`data.adopts` to take a section over on purpose).
- Data, Compliance, Net, Replication, Shop and Policy have no public facade: `StudWork.use` and
  `StudWork.<X>` refuse them.

## Nothing in core is special

The built-in kits use only the public module API. The `special` lint check fails any kit, example
or game module that reaches framework internals (`CompatDoor`, `RuntimeSlot`,
`ServerScriptService.Framework`, another module's server part `ServerScriptService.Modules.<Other>`),
including by enumerating `ServerScriptService` / `Framework` children (`GetChildren` /
`GetDescendants`). A paid currency spent on a non-random good goes through the public
`ctx.compliance.spendPaid`, which any module can call ([module-api.md §19.6](module-api.md#196-ctxcompliancespendpaid-added-in-v130)); the kits hold no
private token.

**The framework half (since v1.3.1).** The framework knows no kit either. `special` also scans
framework code (`packages/framework/{shared,server,client}/**`; not `test/`, specs or the
generated Blink outputs) and `packages/framework/shared/net/framework.blink`, comments stripped,
and fails on:

- any kit module name as a whole word, case-sensitive (the names are read from every
  `packages/kits/*/*/module.luau` `name = "..."`, so a new kit module is covered automatically);
- any Blink event a kit declares in its own `net.blink`, and the v1.2 kit request events
  (`RequestUpgrade`, ...);
- the pre-v1.3.1 kit layout names `Kits`, `ModuleServers`, `ModuleClients`, `kitLoadServer`.

It reads both each comment-stripped line (so `return Mail` and `"Ma" .. "il"` are seen) and the
normalised file (whitespace removed, concatenations folded, `x["Mail"]` read as `x.Mail`), so a
string literal, a field, an index or a split name all count; a mention in a comment does not.
There is no allow-list: every kit ships its own `net.blink`, so `framework.blink` and
`Net.LIMITS` hold only the framework's own events (`StateInit`, `AdminTriggerEvent`, `ClientFunnel`,
`StateSync`, `Feedback`, `EventState`), and the old `net = "framework"` client marker is flagged too.
The lint self-test plants each case; `-- guard: allow special` on a framework line is refused review.

## Game-code guardrails (lint)

`tools/lint` runs `tools/lune/guardrails.luau` over every game and the template:

| Check | Catches |
|---|---|
| `modules` | game code using a kit module the game doesn't list; requiring framework internals |
| `numbers` | balance-looking number literals outside `src/shared/Config` (heuristic) |
| `remotes` | raw remotes and handlers that bypass the framework's Net |
| `purchases` | `ProcessReceipt =`, `Prompt*PurchaseFinished`, `DataStoreService`/`ProfileStore`/`MemoryStoreService`; from v1.7.0 also `ConfigService`, `:GetSecret(`, `:RequestAsync(` and `:PostAsync(` (use `ctx.data.sortedMap`, `ctx.flags`, `ctx.openCloud`; plain `HttpService` JSON calls stay allowed) |
| `strings` (v1.7.0) | hard-coded English in the UI kit, kit client parts and framework client code, and string keys without an English default; not run on game code. See [localization](kits/localization.md). `-- guard: allow strings` skips a line |
| `textfilter` (v1.7.0) | a client-supplied value (any parameter of an action handler after the player, `...` included, unless annotated only `number`/`boolean`; the handler inline or a function defined in the same file, `handler = onRename` or dotted `handler = M.onRename`, also wrapped in a call, `handler = guard(onRename)`; directly or through `..`, `string.sub`, `format`, `lower`, `upper`) reaching a player or a shared store without TextFilter: `ctx.replicate.set/setAll`, `ctx.net.fire/fireAll`, `ctx.data.messages.send`, Mail send, `ctx.data.shared.update`, sorted-map and ordered writes, Notifications `send/schedule`, instance `.Text`/`.Name`/`SetAttribute`; also a whole `Stored` record reaching one. Only what TextFilter returns is clean (`result.public`, `forViewer(...)`, `textFor(...)`, `shown(...)`): passing a name to `filter`, `textFor` or `store` never clears it, so sending the original after filtering it is a finding. Best-effort and same-function only (a handler forwarding the text to a helper, a method handler `M:f` or a table lookup isn't followed); server code of games, examples and kits, not specs or client code. See [textfilter](kits/textfilter.md). `-- guard: allow textfilter` goes on the sink line |
| `packages` | game branches editing `packages/`; in a games repo also the framework pin: `roblox-core/` initialised, exactly at a release tag, no local changes, and its pointer never staged together with game edits ([games-repo.md](games-repo.md)); in a single-game project (v1.5.0) the same against `studwork/`, where any other staged file counts as game work, except in the project's first commit ([single-game-project.md](single-game-project.md)) |

In this repo (not in a games repo), a maintainer committing a deliberate framework change on `main`
or a `core/*` branch can skip the `packages` check with `GUARD_ALLOW_CORE=1 tools/lint` (and the same
variable for the pre-commit hook). It has no effect on other branches or inside a games repo.

Every `.luau` / `.lua` file Rojo would sync is scanned, whatever its name or folder; the only
exclusions are the Blink output files the `.blink` files declare and the Wally folders
(`deps/Packages`, `deps/ServerPackages`), by exact path. The `remotes` and `purchases` checks read a
normalised copy of each file (comments and whitespace removed, so a statement split across lines
is one expression; `"a" .. "b"` joined; `x["Name"]` read as `x.Name`), and `GetService` /
`Instance.new` need a single string literal. Client code is decided by a `client` folder segment,
not a substring.

`--legacy-check` and the listed-file downgrade (below) also cover `textfilter`; `strings` is not scanned in game code and cannot be listed.

A line ending in `-- guard: allow <check>` skips that check for that line; say why on the line
above, and use it rarely.

## Transitional guardrails (adopted projects)

Added in v1.6.0 for a game that adopted StudWork (`tools/adopt --init`, [adopting.md](adopting.md) §5).
Its old code breaks the lint checks on day one, so `studwork-legacy.json` (project root) lists those
files with the checks they may still break and why:

```json
{ "files": [ { "path": "src/server/SaveManager.server.luau", "checks": ["purchases", "numbers"],
               "reason": "old save code; replaced by importLegacy in plan step 3" } ] }
```

- A finding of a listed check in a listed file prints
  `warning: [legacy] <path>:<line>: [<check>] <message> (legacy: <reason>)` and doesn't fail lint.
  Any other check in that file, and every other file, still fails.
- **selene and StyLua skip listed files** (v1.6.0): `tools/lint` prints
  `warning: [legacy] <path>: selene/stylua skipped (legacy: <reason>)` for each (the list comes
  from `lune run tools/lune/guardrails --legacy-files`, which prints `<path>\t<reason>` per valid
  entry; a broken list skips nothing and fails in the guardrails step). Don't reformat old files.
- **`style`:** init lists every old Luau source with the pseudo-check `"style"`: lint skips
  selene/StyLua for it, `tools/typecheck` prints its problems as `warning: [legacy] ...`, and its
  baseline marks it `"style": 0` (never counted; anchored, so `style` can't be added to an entry
  later). A style-only entry never gets "nothing legacy left";
  delete the file when its job moved. Like every entry, it can't be added after the adoption commit.
- A `legacyBaseline` entry for a deleted file is ignored (the baseline can't change after the
  first commit).
- **Counts are per statement:** a re-wrap (StyLua splitting a call over lines) can't raise a
  listed file's count.
- **Never downgraded:** a `ProcessReceipt` assignment, `special` and `packages` fail in a listed
  file too; listing `special` or `packages` is itself an error.
- **It may only shrink:** `studwork.json`'s `legacyBaseline` holds the findings per file and per
  check at init. More findings than the baseline, a file or check the baseline doesn't have, or more
  entries than the baseline fail lint.
- **The baseline is anchored in git:** it must equal the `legacyBaseline` of the first commit that
  added `studwork.json` (`git log --diff-filter=A --reverse`), so editing it, or deleting and
  re-adding `studwork.json`, fails. A shallow clone or a missing history fails closed (fetch the full
  history, as CI does). Before the first commit lint says there's nothing to compare yet.
- **Paths are exact:** relative to the project root, as on disk (no `./`, `..`, other case, or
  symlinks). A listed file that's gone fails ("remove it from studwork-legacy.json"); a listed file
  with no findings left warns ("nothing legacy left; remove the entry").
- **The anchor is local history** (v1.6.1): rewriting history (a squash, `git filter-repo`, a
  fresh repository started from a copy of the files) makes a new "first commit that added
  `studwork.json`" and resets the anchor, and the local check can't see it. Never rewrite an
  adopted project's history; if it happened, restore the old history (or put the old
  `legacyBaseline` and `"adopted": true` back in a commit). `tools/lint --anchor-remote` (below)
  catches it against the remote.
- Every entry needs a non-empty `reason`.
- A project without `"adopted": true` may not have a list at all.

### The adopted marker is sticky (v1.6.1)

`"adopted": true` is anchored like the baseline (`tools/lune/AdoptedMarker.luau`): if **any**
commit reachable from `HEAD` had a `studwork.json` saying adopted, the project counts as adopted,
for lint and for `tools/publish`, whatever the working copy says. Any commit, not only the first:
an adoption can come after `studwork.json` was first committed, and `studwork.json` can be deleted
and re-added; history from `HEAD` only grows, so no later commit can take the flag back (history
is read with `--full-history`, so a side branch that added and removed it counts too). History is
read loosely (any key casing, `true` / `"true"` / `1`); the working copy strictly (only
`"adopted": true`), so `"adopted": "true"`, `"adopted": false` or `"Adopted": true` mean the flag
was removed.

- **Removing the flag** (or `studwork-legacy.json`, or both) **fails lint until
  `tools/adopt --verify .` passes**: lint runs `--verify` (the same command, no second copy of its
  checks) and prints its lines under `studwork.json: [legacy]`. Once `--verify` passes, the flag
  may go: that's graduating (lint prints a note).
- `tools/publish --live` uses the sticky value: an un-flagged but historically adopted project
  still runs `tools/adopt --verify .` and is refused while it fails.
- If the flag is absent and history is shallow or unavailable, lint requires
  `tools/adopt --verify .` to pass instead of assuming the project was never adopted.
  `tools/publish --live` is refused when the sticky history cannot be established.

### `tools/lint --anchor-remote` (v1.6.1, optional)

Runs the whole lint, then compares the anchor and the sticky marker with the **remote default
branch's** history: `refs/remotes/origin/HEAD` (its target), else `refs/remotes/origin/main`, else
`refs/remotes/origin/master`. It reads local remote-tracking refs only and never fetches or pushes
(CI fetches). It fails when the first commit that added `studwork.json` on that branch has a
different `legacyBaseline` than the local one, when the branch's history has that commit and the
local history doesn't, when the branch's history says adopted and the local one doesn't, or in a
shallow clone ("fetch the full history": `fetch-depth: 0` in CI). With no remote default branch it
prints a note and passes; a remote branch without `studwork.json` yet has nothing to compare. A
single-game project gets a CI workflow running it (`.github/workflows/ci.yml`, from
`templates/single-game`; [single-game-project.md](single-game-project.md)).

`lune run tools/lune/guardrails --raw [<dir>]` prints every finding, ignoring the list (that's what
`tools/adopt --init` reads to write the list and the baseline). `guardrails --self-test` plants a
violation for each rule, and `tools/lune/GuardrailsLegacy.spec.luau` runs them in throwaway git repos
(`tools/lune/GuardrailsSticky.spec.luau`: the sticky marker and `--anchor-remote`, v1.6.1).

