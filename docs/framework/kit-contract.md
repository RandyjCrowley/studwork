# Kit contract: what each kit module offers other modules

The fifteen built-in kit modules talk to each other, and to your modules, only through the public
module API ([module API reference](module-reference.md)). This page lists that cross-module
surface in one place: for each kit module, its `api`, `txApi`, `purchaseOps`, `extensions`,
`signals`, replicated keys and save section. The kit pages ([Collection](kits/collection.md),
[Economy](kits/economy.md), [Base](kits/base.md), [Social](kits/social.md),
[Engagement](kits/engagement.md)) have the config keys and the details.

Rules that hold for everything below:

- **Additive only.** Within a major version an entry keeps its name, arguments and meaning; new
  entries are additions. Every v1.2 public function kept its name and meaning in v1.3.
- **Code against this surface, never against a module's internals.** Inside a module, reach a
  dependency through `ctx.deps[Ref]` (api, including `signals`), `ctx.depsTx[Ref]` (txApi) and
  `ctx.depsExt[Ref]` (extensions); purchase handlers use `tx.use(Ref).<op>` (purchaseOps). A
  dependency you don't declare (`dependsOn` or `optional`) isn't reachable. For an optional one,
  check `ctx.isEnabled(Ref)` first.
- **Read views are frozen.** Anything an `api` returns from a save section is a frozen read-only
  view, in every environment.
- **Signals fire after the commit**, from the module's `api.signals` table
  (`ctx.deps[Economy].signals.CurrencyChanged:Connect(fn)`).
- Replicated keys are the module's slice on the client: `StudWork.use(Ref).state()`, or
  `state.modules[<Name>]` with `data` (saved fields listed in `data.replicate`) and `extra`
  (values set with `ctx.replicate`).

## Collection kit

### Items

- **api:** `get(id) -> ItemDef?` (frozen, namespaced item fields included), `all() -> { ItemDef }`,
  `byTag(tag) -> { ItemDef }`, `mutation(id) -> MutationDef?` (frozen, namespaced mutation fields
  such as `economy.incomeMultiplier` included), `mutations() -> { MutationDef }`.
  `register(...)` errors: items exist only through `GameConfig.items`.
- **extensions:** `mutations(list)`: kit-internal hand-over from Rarity (once per runtime). Not for
  other modules.
- **Removed in v1.3.0:** `incomeOf` (Economy computes income from `item.economy.incomePerSec ×
  mutation.economy.incomeMultiplier`), `onRegistered`.
- **Save section:** none.

### Rarity (needs Items)

- **api:** `roll(tableId, player, luck?, opts?) -> (ItemDef?, RollInfo)`, `getOdds(tableId, luck?)`,
  `getOddsDetail(tableId, player?) -> OddsDetail?`, `tiers() -> { TierDef }` (the resolved ordered
  tier list `{ { id, color?, glow?, soundKey? } }`), `setLuck(player, luck, tableId?)`,
  `getLuck(player, tableId?)`.
- **txApi:** `roll(tx, tableId, luck?, opts?) -> (def?, info)`: free unless the tx is a purchase or
  a paid spend; grants only with `opts.grant`.
- **purchaseOps:** `roll(tx, tableId, luck?) -> (def?, info)`: a paid roll that grants the item
  with a `paid:<product>` source.
- **Theme:** contributes `theme.rarity = { tiers = <resolved config.Rarity.tiers> }`.
- **Replicated `extra`:** `odds = { [tableId]: OddsDetail }`, `tiers`.
- **Save section:** `rarity` (pity counters), not replicated.

### Inventory (needs Items)

- **api:** `add(player, itemId, opts?) -> ItemInstance?`, `remove(player, uid, reason?) ->
  ItemInstance?`, `get(player, uid)`, `list(player)` (frozen views), `count(player)`,
  `cap(player)`, `canTrade(player)`, `transfer(from, to, uid, reason) -> (ok, why?)`,
  `sendGift(from, toUserId, uid, reason?) -> (ok, why?)` (needs Mail).
- **txApi:** `add(tx, itemId, opts?) -> ItemInstance?`, `remove(tx, uid, reason?) -> boolean`,
  `list(tx)` (frozen views of the tx working copy), `count(tx)`.
- **purchaseOps:** `addItem(tx, itemId, opts?) -> ItemInstance?`. The `paid:` / `paidcur:` source
  tag is derived from the transaction, never chosen by the caller.
- **extensions:**
  - `onItemRemoved(fn(tx, player, instance))`: fires inside the removing transaction for every
    removal (`remove`, `transfer`, `sendGift`, a rebirth wipe). `ctx.section(tx)` in the hook is the
    registering module's own section. An error in a hook discards the whole tx.
  - `capBonus(id, fn(player) -> number)`: adds to `cap(player)` (Upgrades' `inventoryCap` effect).
- **Mail kind:** owns `"core_gift"`, registered with Mail's `registerKind` when Mail is enabled.
- **signals:** `ItemAdded(player, instance)`, `ItemRemoved(player, instance)`.
- **Replicated `data`:** `inventory`. **Save section:** `inventory`.

## Economy kit

### Economy

- **api:** `grant(player, amount, reason, currency?) -> boolean`, `spend(player, amount, reason,
  currency?) -> boolean`, `balance(player, currency?)`, `addIncomeSource(player, id, perSec)`,
  `removeIncomeSource(player, id)`, `addMultiplier(player, id, mult, expiresAt?, persist?)`,
  `removeMultiplier(player, id)`, `getMultiplier(player)`, `getRate(player)`,
  `primaryCurrency()`, `startingBalance(currency)`. `spend` of a currency in
  `GameConfig.compliance.paidCurrencies` **errors** ("spend a paid currency only through
  compliance.spendForRoll").
- **txApi:** `grant(tx, amount, reason, currency?) -> boolean`, `spend(tx, amount, reason,
  currency?) -> boolean` (same paid-currency refusal), `balance(tx, currency?)` (the tx working
  copy).
- **purchaseOps:** `grant(tx, amount, currency?) -> boolean` (reason `"product:<product>"`).
- **extensions:**
  - `rateFactor(id, fn(player) -> number | { number }) -> invalidate(player)`: a multiplier factor
    read when the income rate is recomputed (Rebirth and Upgrades use it). Call `invalidate` when
    its inputs change.
  - `displayedSource(fn(player) -> { [slotId]: uid }) -> invalidate(player)`: the displayed set for
    `income.source = "displayed"` (Plot registers it). One provider.
- **Compliance:** registers the currency spender for every paid currency it owns
  (`primaryCurrency` and `currencies`).
- **Item fields:** `item.economy.incomePerSec`, `mutation.economy.incomeMultiplier`.
- **signals:** `CurrencyChanged(player, currency, newBalance, delta, reason)`.
- **Replicated:** `data.currency`, `data.multipliers`; `extra.ratePerSec`, `extra.multiplier`.
  **Save section:** `economy`.

### Upgrades (needs Economy)

- **api:** `level(player, id)`, `cost(player, id) -> number?`, `purchase(player, id) -> (ok,
  reason?)`.
- **signals:** `UpgradePurchased(player, upgradeId, level)`.
- **Uses:** Economy's `rateFactor`, Inventory's `capBonus` (optional), Rebirth's `resetStep`
  (optional).
- **Replicated `data`:** `upgrades`. **Save section:** `upgrades`.

### Rebirth (needs Economy)

- **api:** `canRebirth(player)`, `rebirth(player) -> boolean`, `cost(player)`, `multiplier(player)`,
  `count(player) -> number` (v1.7.0, additive: rebirths done; 0 until the player's data is loaded).
- **extensions:** `resetStep(id, fn(tx, player))`: runs inside Rebirth's single transaction, in
  registration order, before the count goes up. Each step writes only its own section through
  `ctx.section(tx)`.
- **signals:** `Rebirthed(player, count)`.
- **Inventory wipe:** a documented config default (`config.Rebirth.onRebirth`): Robux-bought copies
  (`paid:`) are always kept, `paidcur:` and earned copies are wiped unless configured or flagged
  `keepOnRebirth`. Applied through Inventory's `txApi` (optional Inventory).
- **Replicated `data`:** `rebirths`. **Save section:** `rebirth`.

### Offline

- **api:** `onReturn(fn(player, secondsAway)) -> Connection`. Reads `ctx.framework.lastSeen`; with
  `autoPay` it pays through Economy (optional).
- **Save section:** none.

## Base kit

### Plot (needs Inventory)

- **api:** `get(player)`, `owner(plot)`, `display(player, uid, slotId?) -> (ok, reason?)`,
  `clearDisplay(player, uid)`, `slots(player)`, `onAssigned(fn(player, plot))`,
  `displayed(player) -> { [slotId]: uid }` (frozen).
- **signals:** `ItemDisplayed(player, uid, slotId)`, `ItemUndisplayed(player, uid, slotId)`,
  `DisplayCleared(player, slotId)`, `PlotAssigned(player, plot)`, `PlotReleased(player, plot)`.
- **Uses:** Inventory's `onItemRemoved` (clears the slot in the same tx), Rebirth's `resetStep`
  (optional), Economy's `displayedSource` (optional), Items and Rarity (optional, for models and
  tier colours).
- **Replicated:** `data.displayed`; `extra.plotName`. **Save section:** `plot`.

## Social kit

### Friends

- **api:** `onCoPlay(fn(player, friends, kind)) -> Connection`, `friendsInServer(player)`.
- **signals:** `CoPlay(player, friends, kind)`.
- **Uses:** Economy's `addMultiplier` / `removeMultiplier` (optional) for the co-play multiplier.
- **Save section:** none.

### Mail

- **api:** `send(userId, kind, payload, key?) -> boolean` (yields), `onReceive(kind,
  fn(player, payload, info) -> boolean?) -> Connection`, `pending(player)`, `claim(player, id) ->
  (ok, reason?)`. Kinds starting with `core_` are refused here.
- **txApi:** `send(tx, toUserId, kind, payload, key?) -> boolean`: the crash-safe outbox. The
  message leaves only after the tx commits and is saved.
- **extensions:** `registerKind(kind, claimFn(tx, player, payload, info) -> boolean?)`: `claimFn`
  runs inside a tx of the receiver; `false` holds the message in the mailbox (and discards that
  tx); an error retries with backoff and then dead-letters. `core_` kinds are allowed here.
- **Replicated `extra`:** `mailbox`. **Save section:** `mail`, not replicated.

### TextFilter (v1.7.0)

- **api (all yield):** `filter(author, text, context) -> (ok, Filtered | reason)`, `textFor(viewer,
  author, text, context) -> string?`, `store(author, text, context) -> (ok, Stored | reason)`,
  `shown(stored, viewer?) -> string?`, `release(author, stored)` (doesn't yield). Contexts:
  `"public"`, `"friends"`, `"private"`.
- **Uses:** `ctx.policy.allows(player, "IsContentSharingAllowed")`, `ctx.services` (`TextService`,
  `Players`). Friends isn't required.
- **Save section:** `textfilter` (the stored originals; never replicated). The `textfilter` lint
  check ([guardrails](guardrails.md)) expects a game to pass player text through this module.

## Engagement kit

### Streak

- **api:** `onDaily(fn(player, streakDay)) -> Connection`, `get(player) -> { day, lastDay }`,
  `expiresAt(player) -> number?` (v1.7.0, additive: the unix time the streak ends if the player
  doesn't return, i.e. the first instant `advance` would answer reset; nil without a streak).
- **signals:** `StreakAdvanced(player, day)`.
- **Uses:** Economy's `txApi.grant` (optional) for day rewards, in the same tx as the streak write.
- **Replicated `data`:** `streak`. **Save section:** `streak`.

### Leaderboards (v1.7.0)

- **api:** `submit(player, boardId, value) -> boolean`, `top(boardId, previous?) -> { rows, periodId?,
  endsAt?, updatedAt }`, `rank(player, boardId) -> (rank?, value)`, `refresh(boardId) -> boolean`
  (yields).
- **txApi:** `submit(tx, boardId, value) -> boolean`. **extensions:** `registerSource(boardId,
  fn(player) -> number)` (one per board).
- **signals:** `BoardRefreshed(boardId)`. **Uses:** Economy (`balance`), Rebirth (`count`) and Streak
  (`get`) for the built-in sources, all optional; `ctx.data.ordered`, `ctx.data.sortedMap`,
  `ctx.data.census()`.
- **Replicated `extra`:** `boards`, `mine`. **Save section:** `leaderboards`, not replicated.
- **Client:** `board(boardId)`, `mine(boardId)`, `open(boardId?, options?)`, `attach(parent, boardId,
  options?)`; screen `"Leaderboards"`.

### Badges (v1.7.0)

- **api:** `award(player, key) -> boolean` (new record), `has(player, key) -> boolean`.
- **txApi / purchaseOps:** `award(tx, key) -> boolean` (the send follows the commit).
- **signals:** `BadgeAwarded(player, key, badgeId)`. **Uses:** Streak, Rebirth, Inventory, Economy and
  Leaderboards through their public APIs, for the matching trigger kinds only (optional).
- **Replicated `data`:** `awarded`. **Save section:** `badges`. **Client:** `earned()`,
  `onAwarded(fn(key))`.

### Notifications (v1.7.0)

- **api:** `send(userId, templateKey, params?) -> (ok, reason?)`, `schedule(userId, templateKey, at,
  params?, key?) -> (ok, reason?)`, `cancel(userId, key) -> boolean` (all yield),
  `suggestOptIn(player, reason) -> (boolean, reason?)`.
- **signals:** `Sent(userId, templateKey)`, `OptInPrompted(player)`, `LaunchedFrom(player,
  templateKey)` (untrusted: attribution only). **Uses:** `ctx.openCloud`, `ctx.data.sortedMap`,
  Streak's `expiresAt` (optional).
- **Save section:** `notifications` (not replicated); scheduled entries live in a shared sorted
  map, not in a save. **Client:** `canPrompt()`.

## Client side

Each module's client part offers `StudWork.use(Ref)` on the client: its actions (for example
`StudWork.use(Upgrades).actions.upgrade(id)`, `StudWork.use(Inventory).actions.gift(toUserId, uid)`,
`StudWork.use(Mail).actions.claimMail(id)`) and its state slice. HUD widgets are registered with
`UI.registerWidget` under `"Economy.currency"` (Economy) and `"Social.mailbox"` (Mail); the UI kit
registers the default `Odds`, `Inventory` and `Mailbox` screens ([theme guide](theme.md)).
