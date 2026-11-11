# FAQ

**Can I move my existing game to StudWork?**
Yes. Give a coding agent the [migrate prompt](../agents/migrate-prompt.md); it follows the
[playbook](../agents/adopt-existing-game.md): `tools/adopt --audit`, `--init`, port the game system
by system, `tools/adopt --verify`. Studio-only games first get their code extracted with
`tools/adopt --from-place`. You do the cutover yourself ([adopting.md](adopting.md) §2).

**Will my players lose their saves?**
No. Each player's old save is read once when they join (`ctx.data.importLegacy`) and copied into
StudWork in one transaction with a marker, so it's never imported twice. StudWork never writes the
old store. If the read fails, the player is asked to rejoin and no data changes. `tools/test-migration`
checks every old field arrives or is dropped on purpose.

**What about purchases made before the switch?**
They're granted exactly once. PurchaseIds from the old save (`importLegacy.receipts`) or an old
purchase-history store (`ctx.shop.legacyReceipts`) are treated as already granted when Roblox
re-delivers them; anything else goes through the normal receipt-safe path. Items imported from the
old save are tagged paid (`paid:legacy`) unless the old game sold no items.

**Do I have to use every kit?**
No. List only the modules you want (`tools/new-game <name> --modules ...`). A module's hard
dependencies must be listed too; boot names the missing one. `--modules ""` is a foundation-only
game.

**What happens if I call a module the game doesn't list?**
You get an error, `"<Name> is not enabled in GameConfig.modules"`, from `StudWork.use`,
`StudWork.<Name>` or `ctx.deps[...]`. Never a silent nil. Inside a module, check optional
dependencies with `ctx.isEnabled(Ref)` first.

**Why refs instead of strings for dependencies?**
A typo in a `require` fails when the file loads, and `StudWork.use(Ref)` is typed by the
definition. `dependsOn = { "Economy" }` is refused with a message saying so.

**Where does my gameplay code go?**
In the game's own module, `games/<g>/modules/<gameId>/server/init.luau`. It gets a `ctx` like any
module: `ctx.shop.onProduct`, `ctx.data` (the game's own save section), `ctx.deps[...]` for the kit
modules in its `dependsOn`. `Main.server.luau` only builds the world and starts StudWork.

**Can my module read another module's save data?**
Not directly. Use that module's API (`ctx.deps[Inventory].list(player)`) or, inside a
transaction, its `txApi`. Your `ctx.data` and `ctx.section(tx)` only reach your own section.

**How do I change a save shape?**
`tools/make-migration <module>` writes the next `NNN_*.luau`, a test stub and bumps
`data.version`. Fill in the migration and the test, and update `data.default`. A failing migration
saves nothing and kicks the player with their data kept.

**I switched a kit off. Is the data gone?**
No. A disabled module's section is carried through saves untouched; switch it back on and it's
there.

**Why can't I yield in `init` or `start`?**
Boot must be deterministic and fast, and a yield would let requests or purchases interleave with a
half-booted server. Connect events and start loops (`ctx.lifecycle.onTick`) instead; handlers may
spawn their own threads.

**Why can't I yield inside `ctx.tx` / `ctx.data.update`?**
A transaction is a working copy committed at the end. A yield would let another change for the
same player run in between and be overwritten. Put yielding work in `tx.after`.

**How do I give something to another player from inside a transaction?**
Not in the same transaction: one tx is one player. Use `tx.after(function() ... end)`, or Mail's
`txApi.send` for a crash-safe message that leaves only after your save.

**How do I add randomness?**
Register a source with `ctx.compliance.registerRandomSource` and get outcomes from
`ctx.compliance.roll` (free) or `spendForRoll` (priced). That's how odds disclosure and the paid
rules cover your module. Rolling `math.random` yourself for anything a player can buy is outside
the guardrails ([guardrails](guardrails.md)).

**How do I sell something for Robux?**
Add it to `GameConfig.products` and register `ctx.shop.onProduct("<Name>", function(tx) ... end)`
in your module's `init`. Grant through `tx.use(Ref).<op>` (`Economy.grant`, `Inventory.addItem`,
`Rarity.roll`). Never assign `ProcessReceipt`.

**How do I send something to the client?**
Per-player state: `ctx.replicate.set(player, key, value)`; for everyone: `setAll`. Saved fields:
list them in `data.replicate`. One-off messages: your module's Blink events with `ctx.net.fire`,
or `ctx.net.feedback` for toasts and pops.

**How do I take input from the client?**
Declare `actions` in your server part. The framework rate-limits, checks the player is loaded and
`pcall`s; your handler validates the arguments against the player's own data.

**Can I replace a kit's screen or HUD widget?**
Yes: register a screen with the same name (`tools/make-screen <game> Inventory`), or set
`client.hud.widgets["<Module>.<widget>"]` to your component or `false` ([theme guide](theme.md)).

**How do I test without Studio?**
`tools/test <folder>` runs Lune specs. Modules use `StudWork.test.harness` ([module-api.md §15](module-api.md#15-testing-modules));
multi-server scenarios use `StudWork.test.sim`; whole games boot in the sim through their
`Boot.spec.luau`. `tools/make-module` writes a passing test to start from.

**Where's the example of a third-party module?**
[`examples/modules/session-leaderboard`](../../examples/modules/session-leaderboard/README.md):
config, its own section, replicated state, an optional dependency on Economy and its signal, the
shared ticker, a widget and a screen, with tests.

**What may change, and what won't?**
The public API follows semantic versioning: within a major version, changes are additive. The
kits' cross-module surface (APIs, extensions, signals, replicated keys) is listed in
[kit-contract.md](kit-contract.md); the kit pages mark those entries **(contract)**. Release notes
are in the [changelog](../../CHANGELOG.md); known limits in [known-issues.md](../known-issues.md).
