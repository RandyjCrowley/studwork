# Core.Shop (agent A for receipts)

Public API (`Types.ShopAPI`): `onProduct(product, handler)`, `ownsPass(player, pass)`, `onPassOwned(pass, handler)`.

- `init.luau` - service: sets `MarketplaceService.ProcessReceipt`, builds the `PurchaseTx`, pass cache,
  PromptGamePassPurchaseFinished, console `receipt`.
- `Receipt.luau` - pure receipt flow (`Receipt.process`) and the commit step (`Receipt.commit`), injected
  deps. Tested in `Receipt.spec.luau` with the real `Data/Transaction.luau` as the update.

Receipt flow (M4): bad receipt / PurchaseId in flight / player missing / data not loaded -> NotProcessedYet.
Already in `PlayerData.purchases` -> PurchaseGranted `duplicate` (handler not re-run; if this server's save of
it was still unconfirmed, it is saved first). No handler -> NotProcessedYet. Otherwise the handler
(`(data, receipt, tx)`) and `purchases[PurchaseId] = os.time()` run in ONE non-yielding `Data.update`:
- handler error -> nothing committed, `handler_error` (warned with the message);
- handler yields -> nothing committed, `handler_yielded`;
- `tx.retryLater(reason)` -> nothing committed, `retry_later` (not warned). A flag, not the raised value, decides,
  so a handler that pcall-swallows retryLater is still aborted.
Then `Data.saveAsync`: true -> PurchaseGranted `granted`; false -> NotProcessedYet `save_failed`, the record stays
in memory and the effects are parked until the retry (a `duplicate`) confirms a save.

`tx.after` effects, the ProductGranted signal, the toast and `Analytics.custom("ProductPurchased")` run exactly
once, when the grant is saved; never for a declined/erroring handler. A crash between commit and save loses both
the commit and its parked effects, so the next server runs the handler once: one persisted grant overall.
Parked effects of a player who leaves are dropped.

Config: `products.devProducts`, `products.passes` (name -> id; 0 = not created yet: never owned / receipts can't match, warned once).

Console (Studio): `receipt <productName> [purchaseId] [userId]` runs the flow twice with the same PurchaseId and
prints both decisions (expect `granted` then `duplicate`).
