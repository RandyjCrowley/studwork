# Kit contract: what each kit module offers other modules

The twenty-five built-in kit modules talk to each other, and to your modules, only through the public
module API ([module API reference](module-reference.md)). This page lists that cross-module
surface in one place: for each kit module, its `api`, `txApi`, `purchaseOps`, `extensions`,
`signals`, replicated keys and save section. The kit pages ([Collection](kits/collection.md),
[Economy](kits/economy.md), [Base](kits/base.md), [Social](kits/social.md),
[Engagement](kits/engagement.md), [Quests](kits/quests.md), [Carry](kits/carry.md),
[Companions](kits/companions.md), [Player](kits/player.md), [Moderation](kits/moderation.md)) have the config keys and the details.

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
- **extensions (v1.8.0, additive):** `decorate(id, fn(visual, itemDef, instance)) ->
  DecoratorConnection`: a synchronous display decorator, called before size measurement and
  placement. Unique id; stable order; errors are contained. Registering or disconnecting refreshes
  existing displays; the connection's `Invalidate()` refreshes once without changing the order. The
  result is sanitized (scripts, collisions, external references) while unparented; a failure keeps
  the sanitized partial result and a destroyed visual gets a primitive fallback. Register during
  `init`. Plot doesn't depend on the calling module (Companions uses it).

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

## Quests kit

### Quests (v1.8.0)

- **api:** `progress(player, key, amount?) -> boolean` (batched; safe inside a tx), `claim(player, questId) -> (ok,
  reason?)`, `reroll(player, kind, slot) -> (ok, questIdOrReason)`, `active(player) -> { QuestView }`,
  `state(player, questId) -> QuestState?`, `def(questId) -> Quest?`, `grant(player, questId) -> (ok, reason?)` (server only),
  `pin(player, questId, on) -> (ok, reason?)`.
- **extensions:** `registerSource(name, { read, changed? })` (value sources), `registerReward(handler,
  fn(tx, player, params, questId))` (runs inside the claim tx). Call both in `init`.
- **signals:** `Progressed(player, questIds)` (once per live-values send, with the ids whose values
  moved; read them with `state`), `Completed(player, questId)`, `Claimed(player, questId, rewards)`,
  `Rotated(player, kind, periodId)`.
- **Uses:** Economy (`CurrencyChanged`, `balance`, `txApi.grant`), Inventory (`ItemAdded`,
  `ItemRemoved`, `list`, `cap`, `txApi.add`, `txApi.count`), Items (`get`), Rarity (`txApi.roll` at
  luck 1, `getOddsDetail`), Rebirth (`Rebirthed`, `count`), Streak (`StreakAdvanced`, `get`),
  Leaderboards (`BoardRefreshed`, `rank`), all optional and only when the config references them;
  `ctx.events.isActive`, framework signals `EventStarted`/`EventEnded`, `ctx.analytics`.
- **Replicated `extra`:** `board`, `progIds` and `prog` (per player), `questOdds` (shared).
  **Save section:** `quests`, not replicated.
- **Client:** `active()`, `board()`, `onCompleted(fn)`, `onClaimed(fn)`, `open(tab?)`; actions
  `claimQuest`, `rerollQuest`, `pinQuest`, `ackQuest`; screen `"Quests"`; widgets `"Quests.tracker"`,
  `"Quests.button"`.

### Goals (v1.8.0)

- **api:** `current(player) -> GoalView?`, `complete(player, goalId) -> (ok, reason?)` (queued; safe inside a tx),
  `setChain(chain, version?)`, `setNext(fn(player) -> NextGoal?)`, `skip(player, hidden) -> boolean`.
- **extensions:** `registerSource(name, { read, changed? })`.
- **signals:** `GoalChanged(player, goalId?, previousId?)`, `ChainDone(player)`.
- **Uses:** Quests (`def`, `state`, `Completed`, `Claimed`, `Progressed`), Economy, Inventory, Rebirth, Streak
  (value sources), all optional; `ctx.analytics.funnel`, `ctx.gameConfig.analytics` (the funnel
  list, for boot warnings), `ctx.framework.sessions`.
- **Replicated `extra`:** `goal`. **Save section:** `goals`, not replicated. **Theme:** `colors.goalPointer`.
- **Client:** `goal()`, `pointer()`, `onChanged(fn)`, `registerPicker(name, fn)`, `setHidden(hidden)`;
  actions `skipGoals`, `ackGoal`; widget `"Goals.goal"`.

## Carry kit

Both modules live in the kit folder `packages/kits/carry/`.

### Carry (v1.8.0)

- **api:**
  - setup: `registerCarriable(tag, def)`, `setDropRule(tag?, rules)`;
  - actions on objects: `pickUp(player, object) -> (boolean, reason?)`, `drop(player, object) -> boolean`,
    `handOff(player, object, toPlayer) -> (boolean, reason?)`, `releasePlayer(player, reason)`,
    `reportHazard(player, object)`, `reset(object, cframe?) -> boolean`;
  - reads: `holders(object) -> { Player }`, `isCarrying(player) -> Instance?`,
    `objectOf(objectId) -> Instance?`, `stateOf(object) -> CarryState?`;
  - test seam: `useWorld(world)`.
- **actions (client):** `carryPickUp(objectId)`, `carryDrop(objectId)`, `carryHandOff(objectId, toUserId)`.
- **signals:** `PickedUp(player, object, slot)`, `Dropped(object, reason, by?)`, `HandedOff(object,
  from, to, thrown)`, `Delivered(object, zone, carriers, timings)`, `Returned(object, reason)`.
- **Uses:** Movement (optional): `active`, `lastValid`, `velocity`, `signals.RunDisqualified`/`Strike`.
  Without Movement, or while `Movement.active(player)` is false (its flag off), it uses the raw root
  under Carry's own clamp.
- **Replicated `extra`:** `carry:<objectId>` (`setAll`, one encoded string per object, set on state
  changes only). **Save section:** none. **Client:** widget `"Carry.status"`.

### Movement (v1.8.0)

- **api:**
  - runs: `startRun(player, runId)`, `endRun(player, runId) -> (eligible, strikes)`;
  - server moves: `teleport(player, cframe)`, `exempt(player, seconds?, reason)`;
  - reads: `strikes(player) -> { Strike }`, `lastValid(player) -> (CFrame?, trusted)`,
    `active(player?) -> boolean` (policing now: false with the flag off), `velocity(player) -> Vector3?`;
  - setup: `registerVolume(tag, kind)`, `registerPlatformSource(fn)`, `setSpeedCap(player, studsPerSec?)`,
    `setResponse(check, response)`;
  - test seam: `useWorld(world)`.
- **signals:** `Strike(player, reason, details)`, `RunDisqualified(player, runId, reason)`,
  `VolumeCrossed(player, kind, volume)`.
- **Uses:** nothing (a general-purpose validator).
- **Replicated `extra`:** `movement` (`set`, owning player only, `"<strikeCount>|<lastReason>"`, set on
  the first strike and later). **Save section:** none.

## Companions kit

### Companions (v1.8.0, needs Items and Inventory)

- **api:** `equip(player, uid) -> (ok, reason?)`, `unequip(player, uid) -> (ok, reason?)`,
  `equipBest(player) -> (ok, reason?)`, `equipped(player) -> { { uid, itemId, mutation? } }`
  (frozen), `bonus(player) -> number`, `refresh(player) -> (ok, reason?)`,
  `registerLook(key, fn(model, itemDef)) -> Connection`, `applyLook(model, itemDef, mutation?)`.
- **extensions:** `canEquipWith(id, fn(player, copy) -> boolean) -> Connection`,
  `scoreWith(id, fn(player, copy, itemDef) -> number) -> Connection`. Synchronous; unique ids.
  A predicate that errors denies; a malformed score counts as zero.
- **signals:** `EquippedChanged(player, equippedCopies, factor)` after the commit.
- **Uses:** Inventory's `onItemRemoved` for atomic cleanup; optional Economy `rateFactor`, Rebirth
  `resetStep`, Rarity's public tier order, and Plot's `decorate` for display appearance.
- **No txApi or purchaseOps.** Client actions `equip(uid)`, `unequip(uid)` (4/s, burst 8 each),
  `equipBest()` (1/s, burst 2), from its own network declaration.
- **Replicated:** `data.equipped`, `data.manual`, `extra.bonus`, `extra.enabled` (owner);
  `extra.roster` (every client: bounded equipped metadata, no positions or inventories).
  **Save section:** `companions` (`{ equipped = { uid }, manual = false }`).
- **Client:** `open()`, `setLowDetail(boolean)`, `lowDetail()`, `debugStats()`, `registerLook`,
  `applyLook`, `read.equipped/manual/bonus/enabled/roster(state)`; screen `"Companions"`, widget
  `"Companions.open"`. Server and client look registrations are separate.

## Player kit

Two independent modules; either works without the other.

### Codes (v1.8.0)

- **api:** `redeem(player, raw) -> string` (yields; the result key, such as `"ok"` or `"expired"`),
  `define(definition) -> (ok, reason?)`, `disable(id) -> boolean`, `uses(id) -> (number?, reason?)`
  (yields; uncapped gives nil and `"uncapped"`).
- **extensions:** `registerReward(kind, handler(tx, player, reward) -> boolean)` (no yielding, no
  external effects; a false result or an error cancels the whole grant),
  `registerRequirement(kind, predicate)`. Both are also on `api`.
- **signals:** `Redeemed(player, id)`.
- **Uses:** Economy, Inventory, Rarity and Rebirth (all optional, for the rewards and requirements
  a definition names); `ctx.data.shared` for durable global caps (reservations are kept until
  confirmed and finalized once); `ctx.configValues.snapshot()` for live definitions (module-api
  §24.2). Every reward and the redemption record commit in one tx. No paid rewards or paid rolls.
- **Replicated `extra`:** `rollSources` (owner). **Save section:** `codes`, not replicated.
- **Client:** `redeem(raw)`, `open()`; screen `"Codes"`.

### Settings (v1.8.0)

- **api:** `get(player, id)`, `set(player, id, value) -> (ok, reason?)` (saved settings only),
  `register(definition) -> boolean` (before the first player loads; also an extension).
- **signals:** `Changed(player, id, value)`.
- **Uses:** nothing. Client preferences reach the UI kit and Feedback through the local player's
  `CoreUIScale` and `CoreEffectsGroup` attributes (module-api §24.4).
- **Replicated `extra`:** `values`, `revision`, `schema` (owner only: validated saved values and
  acknowledgements; client apply functions never travel). **Save section:** `settings`
  (`{ values = { ... } }`), not replicated directly.
- **Client:** `get(id)`, `set(id, value)`, `onChanged(fn)`, `register(definition)`, `open()`,
  `reset()`; screen `"Settings"`.

## Moderation kit

### Admin (v1.8.0, optional Economy, TextFilter)

- **api:** `can(player, permission) -> boolean` (pure check), `allow(staff, permission, action?) ->
  (boolean, reason?)` (check plus per-staff limits; `"no_permission"`, `"rate_limited"`,
  `"disabled"`; only `ban`/`ban.permanent` actions count `bansPerHour`), `rankOf(player) -> number`,
  `rankOfUserId(userId) -> (ok, rank)` (yields; 0 = not staff), `rankOfChecked(player | userId) ->
  number?`, `studioRoleOnly(userId) -> boolean`, `limitsOf(staff) -> { maxBanSeconds?,
  maxMuteSeconds? }`, `roleOf(player) -> string?`, `isStaff(player) -> boolean`,
  `permissions(player) -> { string }` (frozen), `onlineStaff() -> { Player }`.
- **extensions (init):** `registerPermission(name, { roles? })`, `registerAction(ActionDef)`,
  `registerTab(TabDef)` (ActionDef/RowAction args `{ preset?, duration?, text?, amount?, note? }`;
  RowAction `presets?`, `notes?`), `registerDataView(id, fn(target) -> { [string]: number |
  boolean | string })` (strings must be declared keys), `onStaffMove(fn(staff, target, "to" |
  "bring"))`, `registerAuditSink(fn(AuditRecord))`, `registerTextFilter(fn(author, text) -> (ok,
  shown | reason))`. Reserved: action ids `teleportTo`, `bring`, `spectate`, `stopSpectate`,
  `announce`, `shutdown`, `grant`, `dataView`; tab ids `players`, `announce`, `data`.
- **signals:** `StaffJoined(player, role)`. **Uses:** Economy (optional, the grant action and Data
  balances), TextFilter (optional, free panel text), `ctx.services` (`GroupService`, module-api
  §24.1).
- **Actions:** `run`, `fetch`, `panelOpen` (server to client: `Rows`, `RunResult`, `Spectate`,
  `Announce`).
- **Replicated `extra`:** `staff` (staff players only; absent for everyone else). **Save section:** none.
- **Client:** `isStaff()`, `permissions()`, `role()`, `panel()`.

### Moderation (v1.8.0, optional Admin, TextFilter)

- **api (actions yield):** `ban(target, opts)`, `unban(userId, opts)`, `history(userId, opts) ->
  (ok, { HistoryEntry } | reason)`, `kick(target, opts)`, `serverBan(target, opts)`,
  `mute(target, opts)`, `unmute(target, opts)`, `isMuted(player) -> (boolean, untilTs?)`,
  `warn(target, opts)`, `punish(target, offense, opts) -> (ok, step | reason, status?)`,
  `report(target, source, severity, details?) -> boolean` (never yields; target a Player or user
  id; true when counted), `audit(opts) -> (ok, entries | reason, more?)` (`opts.page`; a day read
  is bounded by `audit.chunksPerRead`), `record(entry, { by }) -> (ok, reason?)` (whitelisted
  actions). Each mutating call takes a required `opts.by: Player | "server" | "console" |
  "system"` (`nil` raises) and returns `(ok, statusOrReason)`. Statuses:
  `"banned"`/`"unbanned"`/`"pending"`; `"done"` (here) or `"sent"` (queued cross-server).
  Reasons: `"no_permission"`, `"outranked"`, `"unknown_rank"`, `"invalid"`, `"no_filter"`,
  `"disabled"`, `"rate_limited"`, `"too_long_for_role"`, `"failed"`, `"unavailable"`.
- **signals:** `Actioned(entry)`, `Muted(player, untilTs?)`, `Banned(userId, seconds)`.
- **Uses:** Admin's api (`allow`, `can`, `rankOf`, `rankOfChecked`, `rankOfUserId`, `limitsOf`) and
  extensions (eight actions, the `audit` tab, the audit sink), TextFilter (staff free text),
  `ctx.data.shared`, `ctx.data.sortedMap("pending")`, `ctx.data.messages`, `ctx.services`
  (`Players`, `TextChatService`).
- **Replicated `extra`:** `muted` (own player). **Save section:** `moderation`, not replicated.
- **Client:** `isMuted()`, `onNotice(fn(key, args))`; screen `"ModerationNotice"`; event `Notice`.

### Reports (v1.8.0, optional Admin, Moderation, TextFilter)

- **api:** `submit(reporter, targetUserId, category, note?) -> (ok, reason?)` (yields),
  `queue(opts) -> (ok, { ReportSummary } | reason)`, `detail(reportId, opts) -> (ok, Report |
  reason)`, `claim(reportId, opts)`, `resolve(reportId, resolution, opts)`,
  `registerContext(fn(targetUserId, target?) -> table?)` (also an extension).
- **signals:** `Submitted(reportId, targetUserId, category)`, `Resolved(reportId, resolution)` (never
  a reporter id).
- **Uses:** Admin (`registerTab` with `claim`/`resolve` row actions, `allow`, `can`, ranks for the
  viewer rules), Moderation (`report` for auto actions, `record` on claim and resolve), TextFilter
  (notes), `ctx.data.shared`, `ctx.data.sortedMap("queue")`. Reporter ids are shown only to
  `reports.reporters`.
- **Actions:** `submit`.
- **Replicated `extra`:** `recent` (`setAll`, `{ userId, name }`). **Save section:** `reports`, not
  replicated.
- **Client:** `open(targetUserId?)`, `recent()`, `read`; screen `"Report"`.

## Client side

Each module's client part offers `StudWork.use(Ref)` on the client: its actions (for example
`StudWork.use(Upgrades).actions.upgrade(id)`, `StudWork.use(Inventory).actions.gift(toUserId, uid)`,
`StudWork.use(Mail).actions.claimMail(id)`) and its state slice. HUD widgets are registered with
`UI.registerWidget` under `"Economy.currency"` (Economy) and `"Social.mailbox"` (Mail); the UI kit
registers the default `Odds`, `Inventory` and `Mailbox` screens ([theme guide](theme.md)).
v1.8.0 kits add the widgets `"Quests.tracker"`, `"Quests.button"`, `"Goals.goal"`, `"Carry.status"`
and `"Companions.open"`, and the screens `"Quests"`, `"Companions"`, `"Codes"`, `"Settings"`,
`"ModerationNotice"` and `"Report"`.
