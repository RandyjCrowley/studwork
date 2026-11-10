# Core.Shop (agent E)

Public API (`Types.ShopAPI`): `onProduct(product, handler)`, `ownsPass(player, pass)`, `onPassOwned(pass, handler)`.

- `init.luau` - service: sets `MarketplaceService.ProcessReceipt`, pass cache, PromptGamePassPurchaseFinished, console `receipt`.
- `Receipt.luau` - pure receipt decision (pinned flow), injected deps. Tested in `Receipt.spec.luau`.

Receipt flow: in-flight PurchaseId -> NotProcessedYet; player missing / data not loaded -> NotProcessedYet;
already in `PlayerData.purchases` -> PurchaseGranted (handler not re-run); no handler / handler error / handler
returns non-true -> NotProcessedYet; record `purchases[PurchaseId] = os.time()` -> `Data.saveAsync` -> only `true`
returns PurchaseGranted (otherwise NotProcessedYet, id stays recorded so the retry grants without re-running).

Config: `products.devProducts`, `products.passes` (name -> id; 0 = not created yet: never owned / receipts can't match, warned once).

Console (Studio): `receipt <productName> [purchaseId] [userId]` runs the flow twice with the same PurchaseId and
prints both decisions (expect `granted` then `duplicate`).
