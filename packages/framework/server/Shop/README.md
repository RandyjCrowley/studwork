# Framework Shop (StudWork, core v1.3.0)

Framework internal (module-api.md §7, §7.1). Modules reach it only through their scoped
`ctx.shop = { onProduct, onPassOwned, ownsPass }`; there is no `ModuleRef` and no `StudWork.use(Shop)`.

- `init.luau` - the service: products by name or id, the `PurchaseTx`, the exclusive `ProcessReceipt`
  claim and runtime owner check, gamepass cache + `PromptGamePassPurchaseFinished` (through the Platform
  adapter), N9 settlement on leave, console `shop receipt`.
- `Receipt.luau` - the pure v1.2 receipt flow (`Receipt.process`) and commit step (`Receipt.commit`),
  unchanged from v1.2. `Receipt.spec.luau` tests it in isolation; `packages/framework/test/Services.spec.luau`
  and `ShopCompliance.spec.luau` prove the same cases end to end through the framework Shop and Data.

## Receipt guarantees (kept from v1.1/v1.2)

`ctx.shop.onProduct(product, handler(tx))`: one handler per product, owned by the registering module.
`tx` is the sealed data tx plus `paid` (always true), `paidRandomRestricted`, `policyKnown`, `productName`,
`receipt`, `after(fn)`, `retryLater(reason?)`, `use(ref)` (the purchase ops of the handler's own module or a
declared dependency).

1. Bad receipt / PurchaseId already in flight / player not in this server / data not loaded ->
   `NotProcessedYet`.
2. Already in `_framework.purchases` -> `PurchaseGranted` (`duplicate`): the handler never runs twice. If this
   server committed it and the save is still unconfirmed, the save is retried first.
3. The handler and `_framework.purchases[PurchaseId] = now` land in ONE non-yielding framework transaction.
   Handler error -> nothing written (`handler_error`, warned); yield -> nothing written (`handler_yielded`);
   `tx.retryLater` -> nothing written (`retry_later`, quiet; a flag decides, so a pcall-swallowed retry still
   aborts). Compliance calls `tx.retryLater` itself when a paid roll meets an unknown policy.
4. Then `Data.saveAsync`: confirmed -> `PurchaseGranted`; not confirmed -> `NotProcessedYet` (`save_failed`),
   the record stays in memory and the effects are parked until a confirmed save.
5. `tx.after` effects, the framework signal `ProductGranted`, a toast and analytics `ProductPurchased` run
   exactly once, after the grant's save is confirmed; never for a declined or erroring handler. A crash
   between commit and save loses the commit and its parked effects together, so the next server runs the
   handler once: one persisted grant overall.

## N9: after-purchase effects when the player has left (core v1.3.0 decision)

**`tx.after` effects run even if the buyer has left, as long as the grant's save is confirmed.** When a
player leaves while one of their grants is parked (its save failed once), the runtime calls
`Shop.settleOnLeave` before Data releases the player: one more confirmed save is attempted (the PurchaseIds
stay in flight meanwhile, so a concurrent Roblox retry gets `NotProcessedYet`, never an unconfirmed grant).

- Save confirmed: the parked effects run now, once, followed by `ProductGranted` and `ProductPurchased`. The
  next server only sees a duplicate and runs nothing.
- Save not confirmed either: the effects are dropped with a warning; `ProductPurchased` is still logged. The
  grant itself persists if the session-end save lands (the next server sees a duplicate); if it doesn't, the
  next server runs the handler and its effects once.

So write `tx.after` effects that **don't need the buyer to still be in the server**: analytics, a
cross-player send through `ctx.data.messages` / Mail, a signal. Anything that talks to the buyer (a toast, a
sound) must tolerate the player being gone (`ctx.net.feedback` already ignores a player who left).
**Never put the grant itself in `tx.after`**: write it through `ctx.section(tx)` / `tx.use(ref)` so it is part
of the receipt's commit. This uses the frozen API unchanged (`tx.after(fn)`); only the delivery rule is new.

## §7.1: the exclusive ProcessReceipt owner

- Shop assigns `MarketplaceService.ProcessReceipt` (through `platform.marketplace.setProcessReceipt`) as the
  very last boot step, after every module's `init` and `start` and after Net released its queued requests.
- Every `Shop.RECEIPT_CHECK_SECONDS` of the runtime ticker (Heartbeat), `checkReceiptOwner` reads the current
  callback through `platform.marketplace.getProcessReceipt()`. A replacement is a `warn` naming the source
  (`debug.info(fn, "sl")`, or "unknown source"), an analytics custom event `ProcessReceiptHijacked` with
  `{ source }` as a custom field (logged against a player in the server), and Shop reassigns its own function.
  `shop.receiptCheck()` returns `{ status, hijacks }`.
- **Limit on the live engine:** `ProcessReceipt` is a write-only callback ("you can only set the callback
  value, get is not available"), so the live adapter's `getProcessReceipt` reports it unreadable and the
  runtime check is inert there (`status = "unavailable ..."`). It is fully exercised with the fake platform
  in the Lune tests and turns on by itself if the engine ever allows the read. The enforcement that works
  everywhere is the lint guardrail: `tools/lune/guardrails.luau` check `purchases` bans any other
  `ProcessReceipt` assignment, `Prompt*PurchaseFinished` use, and direct `DataStoreService` / `ProfileStore`
  use, in game code and in `packages/` outside the framework (allow-list in `Guard.PURCHASES_ALLOWED`).

## Items

Items exist only through `GameConfig.items`. There is no register function anywhere; a register-style call
errors "items must be declared in GameConfig.items; registering items after start is not supported in
core-v1.3.0" (CHANGELOG, Breaking). Tested in `packages/framework/test/Items.spec.luau`.

Config: `products.devProducts`, `products.passes` (name -> id; 0 = not created yet: never owned, receipts can't
match, warned once).

Console (Studio): `shop receipt <productName> [purchaseId] [userId]` runs the flow twice with the same
PurchaseId and prints both decisions (expect `granted` then `duplicate`).
