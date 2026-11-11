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
- **Limit (known issue R16): on a live server a replacement can't be detected at runtime.**
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
  currency errors; its `api.spend` does too once the Economy rewrite lands (PHASE1-CONTRACT.md;
  the bridged v1.2 `spend` keeps its v1.2 behaviour until then). There is no "free roll" escape: a
  genuinely free reward calls `roll`.
- Every currency in `GameConfig.compliance.paidCurrencies` has a spender (core-v1.3.1, R20; was
  guided): once every module has run `init` and `start`, boot fails closed if a listed currency
  has no spender registered through `ctx.compliance.registerCurrencySpender` ("compliance.paidCurrencies
  lists 'Gems', but no enabled module registered a spender for it ..."). A paid currency can no
  longer be listed while `spendForRoll` / `spendPaid` would error on every call because its owner
  isn't enabled. What this checks is that *a* spender exists, one per currency (a second
  registration errors); not which module registered it, nor that the spender debits the right
  balance (module-api.md §19.10).
- Luck on a paid roll is refused unless the source discloses luck and that player was sent exactly
  those odds (`ctx.replicate.sent`).
- Unknown policy: retried later inside a purchase, refused outside. Restricted: refused with
  `"restricted"`; grant a fixed non-random fallback.

What can **only be guided**:

- A module that keeps a paid currency's balance in its own data section can still debit it
  directly, without going through its registered spender / `spendForRoll` (Economy's own
  `txApi.spend` refuses, but the framework can't see a third-party module writing its own section).
  The boot check only proves a spender exists; that residual of R20 stays guided (docs, review).

- Module code can still invent randomness outside these APIs (`math.random`, `Random.new`) and
  never register a source. The framework can't see that. The docs, the generator templates and a
  planned lint heuristic (`math.random`/`Random.new` near a currency grant/spend or an item grant)
  steer authors to Compliance; code review is the backstop.
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
`ctx.compliance.spendPaid`, which any module can call (module-api.md §19.6); the kits hold no
private token.

**The framework half (core-v1.3.1, R19).** The framework knows no kit either. `special` also scans
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
The only allow-list is `TRANSITIONAL_V131` in `tools/lune/guardrails.luau`: the seven kit request
events still in `framework.blink` / `Net.LIMITS` and the `net = "framework"` client marker, until
each kit ships its own `net.blink` (core-v1.3.1 Phase 2); Phase 3 deletes it.

## Game-code guardrails (lint)

`tools/lint` runs `tools/lune/guardrails.luau` over every game and the template:

| Check | Catches |
|---|---|
| `modules` | game code using a kit module the game doesn't list; requiring framework internals |
| `numbers` | balance-looking number literals outside `src/shared/Config` (heuristic) |
| `remotes` | raw remotes and handlers that bypass the framework's Net |
| `purchases` | `ProcessReceipt =`, `Prompt*PurchaseFinished`, `DataStoreService`/`ProfileStore` |
| `packages` | game branches editing `packages/` |

Every `.luau` / `.lua` file Rojo would sync is scanned, whatever its name or folder; the only
exclusions are the Blink output files the `.blink` files declare and the Wally folders
(`deps/Packages`, `deps/ServerPackages`), by exact path. The `remotes` and `purchases` checks read a
normalised copy of each file (comments and whitespace removed, so a statement split across lines
is one expression; `"a" .. "b"` joined; `x["Name"]` read as `x.Name`), and `GetService` /
`Instance.new` need a single string literal. Client code is decided by a `client` folder segment,
not a substring.

A line ending in `-- guard: allow <check>` skips that check for that line; say why on the line
above, and use it rarely.
