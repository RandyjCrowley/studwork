--!strict
--[[
	Core public interface. FROZEN at tag core-contract-v1.2 (previously core-contract-v1.1, v0).

	ADDITIVE ONLY: new fields/functions/types may be added; nothing is ever renamed or removed.
	Deprecate instead (keep it working, mark it `-- @deprecated <why, replacement>`).
	Every change is recorded in packages/core/CHANGELOG.md. The one-off non-additive changes
	made before any game existed are listed there under "Breaking (pre-games)" (core-v1.1.0).

	This module is pure (no Roblox globals at load time) so Lune tests and luau-lsp can read it.
	Colours are hex strings ("#RRGGBB"); convert with Color3.fromHex at runtime (see Palette.luau).
]]

local Types = {}

--------------------------------------------------------------------------------
-- Rarity, mutations, items
--------------------------------------------------------------------------------

export type RarityTier = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic" | "Secret"

export type RarityTierDef = {
	id: RarityTier,
	order: number, -- 1 = Common ... 7 = Secret
	color: string, -- hex, main colour (badges, outlines, particles)
	glow: string, -- hex, glow/aura colour
	glowStrength: number, -- 0..1, how strong the aura/flash is
	soundKey: string, -- key in core/shared/Sounds.luau
}

export type Mutation = {
	id: string, -- e.g. "Gold"
	name: string,
	multiplier: number, -- income multiplier applied on top of ItemDef.incomePerSec
	color: string?, -- hex tint
	weight: number?, -- relative weight when a mutation is rolled (see RarityTableConfig.mutationChance)
}

export type ItemDef = {
	id: string, -- unique, stable forever (saved in player data)
	name: string,
	rarity: RarityTier,
	incomePerSec: number, -- base income while the item earns (see BalanceConfig.income.source)
	model: string?, -- name of a Model under the game's assets folder (ReplicatedStorage.Game.Assets); nil = placeholder
	icon: string?, -- "rbxassetid://..." image
	source: string?, -- where it comes from: "drop" | "roll" | "shop" | "event" | "gift" | game-defined
	tags: { string }?, -- free-form, e.g. {"Shelf"} for Example Shop evidence, {"Plant"}
	-- Rebirth with keepInventory = false: is a copy of this item kept? nil (default) = kept only
	-- when the copy came from a paid source (ItemInstance.source starts with "paid:"), wiped
	-- otherwise. true = always kept, false = always wiped (even when bought with Robux).
	keepOnRebirth: boolean?,
}

-- One owned copy of an item. Saved in PlayerData.inventory keyed by uid.
export type ItemInstance = {
	uid: string, -- globally unique (GUID) so items can move between players
	itemId: string,
	mutation: string?, -- Mutation.id
	acquiredAt: number, -- unix seconds (os.time())
	-- How this copy was obtained ("roll", "gift", ...). "paid:<id>" = obtained with Robux (a paid
	-- roll, a roll priced in a paid currency, or PurchaseTx.addItem): untradeable for
	-- paid-random-restricted players and kept on rebirth by default (ItemDef.keepOnRebirth).
	source: string?,
	meta: { [string]: string | number | boolean }?, -- small per-copy game data (keep tiny; it is saved)
}

export type InventoryAddOptions = {
	mutation: string?,
	source: string?,
	meta: { [string]: string | number | boolean }?,
	reason: string?, -- analytics / logging reason
}

export type RollOptions = {
	paid: boolean?, -- true when the roll was bought with Robux. Blocked for paid-random-restricted players.
	reason: string?,
	grant: boolean?, -- true = also add the rolled item to the player's inventory (default false)
	-- v1.2 (review R4): a roll of a table priced in a balance.paidCurrencies currency counts as
	-- PAID (policy block, luck rule, "paidcur:" tag) unless free = true (a reward roll nobody paid
	-- for). Ignored for `paid = true` tables (always paid).
	free: boolean?,
}

export type RollInfo = {
	ok: boolean,
	reason: string?, -- set when ok == false: "unknown_table" | "restricted" | "not_loaded" | "inventory_full" | ...
	mutation: string?, -- rolled mutation id (nil = none)
	pity: boolean, -- true when the pity guarantee forced this result
	instance: ItemInstance?, -- set when opts.grant == true and the item was added
}

--------------------------------------------------------------------------------
-- Player data (saved)
--------------------------------------------------------------------------------

export type MultiplierEntry = {
	mult: number,
	expiresAt: number?, -- unix seconds; nil = no expiry
}

export type StreakState = {
	day: number, -- current streak day (1 = first day). 0 = never claimed.
	lastDay: number, -- UTC day index (os.time() // 86400) of the last counted day. 0 = never.
}

export type PlayerData = {
	schemaVersion: number,
	currency: { [string]: number }, -- currencyId -> balance. Primary id = BalanceConfig.primaryCurrency
	inventory: { [string]: ItemInstance }, -- uid -> instance
	displayed: { [string]: string }, -- plot slotId -> uid (items shown on the plot)
	upgrades: { [string]: number }, -- upgradeId -> level
	rebirths: number,
	multipliers: { [string]: MultiplierEntry }, -- persisted multipliers (timed boosts etc.)
	streak: StreakState,
	lastSeen: number, -- unix seconds, written on leave and periodically
	firstJoin: number, -- unix seconds
	purchases: { [string]: number }, -- receipt PurchaseId -> unix seconds granted (double-grant guard)
	pity: { [string]: number }, -- rarity tableId -> rolls since last pity-tier result
	stats: { [string]: number }, -- free counters (totalEarned, itemsCollected, ...)
	funnel: { [string]: number }, -- funnel step -> unix seconds first reached (each step logged once)
	game: { [string]: any }, -- [GameConfig.gameId] = that game's own table (see GameDataConfig)
	mail: MailState, -- Core.Mail bookkeeping (idempotency keys, retries, dead letters). Server-only.
}

-- Saved Core.Mail state. Not replicated to the client.
export type MailDeadLetter = {
	id: string, -- idempotency key
	kind: string,
	payload: { [string]: any },
	attempts: number,
	error: string, -- last handler error (truncated)
	at: number, -- unix seconds it was dead-lettered
}

export type MailState = {
	seen: { [string]: number }, -- idempotency key -> unix seconds processed (bounded, oldest pruned)
	attempts: { [string]: number }, -- key -> handler ERRORS so far (cleared on success/dead letter)
	dead: { MailDeadLetter }, -- messages that failed every attempt (bounded, oldest dropped)
	-- v1.2 (N1). Absent in older saves; Mail creates them on first use.
	box: { [string]: MailboxEntry }?, -- the mailbox: id -> message a handler couldn't accept yet
	outbox: { [string]: MailOutboxEntry }?, -- key -> message committed but not sent yet (sendInto)
}

-- A message whose handler returned `false` ("can't accept it now", e.g. the inventory is full).
-- It waits in PlayerData.mail.box with no time limit until Mail.claim succeeds (N1). Holding a
-- message is a capacity condition, never a failure: it never counts toward dead-lettering.
export type MailboxEntry = {
	id: string, -- idempotency key (MailInfo.id)
	kind: string,
	payload: { [string]: any },
	sentAt: number, -- unix seconds the sender sent it
	heldAt: number, -- unix seconds it entered the mailbox
}

-- A message written in the SAME Data.update as its cause (e.g. the item leaving the sender's
-- inventory for a gift) and sent after that update commits. Kept until MessageAsync succeeds,
-- retried on the sender's next load, so the cause and the message can't be separated.
export type MailOutboxEntry = {
	toUserId: number,
	kind: string,
	payload: { [string]: any },
	key: string, -- idempotency key used for the send (a retried send can't deliver twice)
	at: number, -- unix seconds it was written
}

--------------------------------------------------------------------------------
-- Game config (balance numbers live here, never in core code)
--------------------------------------------------------------------------------

export type RarityTableEntry = {
	itemId: string,
	weight: number, -- relative weight (> 0)
}

export type RarityTableConfig = {
	entries: { RarityTableEntry },
	cost: { currency: string, amount: number }?, -- for player-requested rolls (Actions.roll). nil = server-only table
	paid: boolean?, -- true = bought with Robux -> paid random item rules apply (odds shown, policy check)
	luckMinTier: RarityTier?, -- luck multiplies weights of tiers >= this (default "Rare")
	-- true = odds of this table are disclosed PER PLAYER including that player's luck
	-- (Rarity.getOddsDetail(tableId, player) -> ReplicatedState.odds). Only such a table may take a
	-- PAID roll with luck ~= 1, and only once the player's client has received those odds (N4).
	luckDisclosed: boolean?,
	pity: { threshold: number, minTier: RarityTier }?, -- after `threshold` rolls below minTier, force >= minTier
	mutationChance: number?, -- 0..1 chance the result gets a mutation (weighted by Mutation.weight)
}

export type UpgradeConfig = {
	name: string,
	baseCost: number,
	costGrowth: number, -- cost(level) = baseCost * costGrowth ^ level
	currency: string?, -- default primary
	maxLevel: number,
	effect: "incomeMultiplier" | "inventoryCap" | "custom",
	perLevel: number, -- incomeMultiplier: +perLevel per level (1 + level*perLevel); inventoryCap: +perLevel slots
	resetsOnRebirth: boolean?, -- default true
}

export type RebirthConfig = {
	baseCost: number,
	costGrowth: number, -- cost(n) = baseCost * costGrowth ^ rebirths
	currency: string?, -- default primary
	multiplierPerRebirth: number, -- income multiplier = 1 + rebirths * multiplierPerRebirth
	keepInventory: boolean,
	keepDisplayed: boolean?,
	resetCurrencies: { string }?, -- default {primary}
	maxRebirths: number?,
}

export type OfflineConfig = {
	capSeconds: number, -- seconds away are capped to this
	minSeconds: number, -- below this, no offline handling
	payoutFraction: number, -- 0..1 of the live rate paid while away (when autoPay)
	autoPay: boolean, -- true = core pays rate * seconds * fraction; handlers still run
}

export type StreakConfig = {
	graceHours: number, -- a missed UTC day is forgiven if the player returns within this many hours after it ends
	rewards: { { day: number, currency: string?, amount: number } }?, -- optional auto-rewards by streak day
	loopAfter: number?, -- after this many days the reward table loops (streak count keeps going)
}

export type FriendsConfig = {
	checkIntervalSec: number, -- how often in-server friend detection re-runs
	coPlayMultiplier: number?, -- optional income multiplier while playing with friends (core applies it)
}

export type IncomeConfig = {
	tickSeconds: number, -- payout interval (1 = every second)
	source: "displayed" | "owned", -- which items earn: shown on the plot, or everything owned
}

export type BalanceConfig = {
	primaryCurrency: string,
	-- Currencies players can buy with Robux (directly or via packs). Rolls costing these count as
	-- paid random items: restricted players can't roll and results are tagged "paid:<table>".
	paidCurrencies: { string }?,
	startingCurrency: { [string]: number }?,
	starterItems: { string }?, -- item ids granted on first join (and displayed if possible)
	-- Module sections: required when that module is listed in GameConfig.modules (ConfigValidate
	-- enforces it), ignored otherwise. Services of an enabled module may assume they exist.
	income: IncomeConfig?, -- Economy
	multiplierStacking: "multiply" | "add"?, -- default "multiply"
	inventory: { cap: number }?, -- Inventory
	rarityTables: { [string]: RarityTableConfig }?, -- Rarity
	mutations: { Mutation }?,
	upgrades: { [string]: UpgradeConfig }?, -- Upgrades
	rebirth: RebirthConfig?, -- Rebirth
	offline: OfflineConfig?, -- Offline
	streak: StreakConfig?, -- Streak
	friends: FriendsConfig?, -- Friends
	plot: { slotCount: number?, autoDisplay: boolean? }?, -- autoDisplay: new items go to a free slot
}

export type ProductsConfig = {
	passes: { [string]: number }, -- name -> gamepass id
	devProducts: { [string]: number }, -- name -> developer product id
}

export type EventSchedule = {
	weekday: number?, -- 1 = Sunday ... 7 = Saturday (os.date("!*t").wday). nil = every day
	hourUtc: number, -- 0..23
	minuteUtc: number?, -- 0..59
}

export type EventDef = {
	schedule: EventSchedule?,
	durationSec: number,
	data: { [string]: any }?, -- game-defined payload passed to the handler
}

export type EventsConfig = { [string]: EventDef }

export type GameDataConfig = {
	defaults: { [string]: any }, -- default value of PlayerData.game[gameId]
	version: number?, -- current game-table version (default 1)
	migrations: { [number]: (old: { [string]: any }) -> { [string]: any } }?, -- [toVersion] = fn
}

-- Core.Mail delivery tuning (reliability rails, not balance). Every field is optional.
export type MailConfig = {
	-- Handler ERRORS (not `false`) before a message is dead-lettered. Counted across sessions.
	maxAttempts: number?, -- default 10
	-- Wait before retry n: min(max, base * factor^(n-1)) seconds. Default { 30, 2, 900 }, i.e.
	-- about 75 minutes of retries inside one session before the attempts carry to the next one.
	backoff: { base: number, factor: number, max: number }?,
	-- Max messages held in one player's mailbox (default 500). Beyond it a message is left queued
	-- in ProfileStore and offered again next session. ProfileStore keeps at most 1000 queued
	-- messages per profile and DROPS THE OLDEST beyond that (known issue R1): don't flood one user.
	mailboxCap: number?,
}

export type AnalyticsConfig = {
	funnel: { string }, -- ordered onboarding steps; index = step number sent to AnalyticsService
	clientSteps: { string }?, -- steps the client may report (UI-only steps); everything else is server-only
}

export type PaletteOverrides = { [string]: string } -- palette key -> hex

-- Optional core modules a game switches on in GameConfig.modules. The foundation (Data, Net,
-- Shop, Analytics, Policy, Events, Console, Replication; client UI kit, Feedback, Input, Hud) is
-- always on. Dependencies: packages/core/shared/Modules.luau. Core.start errors on an unknown
-- name or a missing dependency; calling a module that is not enabled errors with
-- "<Name> is not enabled in GameConfig.modules".
export type ModuleName =
	"Economy"
	| "Upgrades"
	| "Inventory"
	| "Rarity"
	| "Items"
	| "Plot"
	| "Rebirth"
	| "Offline"
	| "Streak"
	| "Friends"
	| "Mail"

-- Server-only settings, passed as the second argument of Core.start on the server. Keep this
-- module under ServerScriptService/ServerStorage so clients never receive it.
export type ServerConfig = {
	admins: { number }?, -- user ids allowed to trigger events / admin commands on live servers
}

export type GameConfig = {
	gameId: string, -- stable key: PlayerData.game[gameId], DataStore name suffix, remote scope
	modules: { ModuleName }, -- optional modules to switch on (see ModuleName). {} = foundation only
	items: { ItemDef }, -- {} when the Items module is off
	balance: BalanceConfig,
	products: ProductsConfig,
	events: EventsConfig,
	palette: PaletteOverrides?,
	-- @deprecated replicated to every client (L5). Use ServerConfig.admins (Core.start's second
	-- argument on the server). Still honoured, with a warning.
	admins: { number }?,
	data: GameDataConfig?,
	analytics: AnalyticsConfig?,
	mail: MailConfig?, -- Mail module delivery tuning (optional)
	assetsFolderName: string?, -- child of ReplicatedStorage holding item models (default "GameAssets")
}

--------------------------------------------------------------------------------
-- Signals
--------------------------------------------------------------------------------

export type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean,
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
}

export type CoPlayKind = "server" | "invite" | "private"

export type EventContext = {
	id: string,
	startedAt: number, -- unix seconds
	endsAt: number,
	data: { [string]: any }?,
	triggeredBy: Player?, -- set for admin/console triggers
}

export type CoreSignals = {
	DataLoaded: Signal<Player, PlayerData>,
	DataChanged: Signal<Player>, -- fired (deferred, coalesced per frame) after Data.update
	CurrencyChanged: Signal<Player, string, number, number, string>, -- player, currencyId, newBalance, delta, reason
	ItemAdded: Signal<Player, ItemInstance>,
	ItemRemoved: Signal<Player, ItemInstance>,
	ItemDisplayed: Signal<Player, string, string>, -- player, uid, slotId
	ItemUndisplayed: Signal<Player, string, string>,
	Rebirthed: Signal<Player, number>, -- player, new rebirth count
	UpgradePurchased: Signal<Player, string, number>, -- player, upgradeId, new level
	StreakAdvanced: Signal<Player, number>,
	CoPlay: Signal<Player, { Player }, CoPlayKind>,
	EventStarted: Signal<EventContext>,
	EventEnded: Signal<EventContext>,
	ProductGranted: Signal<Player, number, string>, -- player, productId, purchaseId
	PlotAssigned: Signal<Player, Model>,
	PlotReleased: Signal<Player, Model>,
}

--------------------------------------------------------------------------------
-- Server namespaces
--------------------------------------------------------------------------------

export type ItemsAPI = {
	register: (defs: { ItemDef }) -> (),
	get: (id: string) -> ItemDef?,
	all: () -> { ItemDef },
	byTag: (tag: string) -> { ItemDef },
	incomeOf: (instance: ItemInstance) -> number, -- incomePerSec * mutation multiplier
}

-- Full disclosure of a rarity table (paid-random-item odds). All probabilities are 0..1.
export type OddsMutation = {
	id: string,
	name: string,
	probability: number, -- chance of this mutation on any roll (mutationChance * weight share)
}

export type OddsOutcome = {
	itemId: string,
	mutation: string?, -- nil = no mutation
	probability: number, -- final chance of exactly this (item, mutation) on a normal roll
}

export type OddsPity = {
	threshold: number, -- every `threshold`-th roll without a result >= minTier is forced to >= minTier
	minTier: RarityTier,
	items: { [string]: number }, -- itemId -> probability on a forced (pity) roll
}

export type OddsDetail = {
	tableId: string,
	paid: boolean, -- bought with Robux, or priced in a balance.paidCurrencies currency
	items: { [string]: number }, -- itemId -> base probability on a normal roll (sums to 1)
	mutationChance: number, -- chance a roll gets any mutation
	mutations: { OddsMutation },
	outcomes: { OddsOutcome }, -- items x mutations on a normal roll (sums to 1)
	pity: OddsPity?,
	-- v1.2 (N4): the luck these odds include (1 = none) and whether the table discloses per-player
	-- luck (RarityTableConfig.luckDisclosed). Shared (all-player) odds always have luck = 1.
	luck: number?,
	luckDisclosed: boolean?,
}

export type RarityAPI = {
	roll: (tableId: string, player: Player, luck: number?, opts: RollOptions?) -> (ItemDef?, RollInfo),
	getOdds: (tableId: string, luck: number?) -> { [string]: number }, -- itemId -> probability (sums to 1)
	-- Everything a player needs to see before a paid roll: base odds, mutation odds, the final
	-- probability of each outcome and the pity rule. nil = unknown table. Replicated to clients as
	-- ReplicatedState.odds[tableId] for every table with a cost or `paid = true`, and re-sent when
	-- Items.register adds items after start (N3).
	-- With `player` (v1.2, N4) the odds include that player's current luck (getLuck) when the
	-- table has `luckDisclosed = true`; otherwise luck = 1. `detail.luck` says which.
	getOddsDetail: (tableId: string, player: Player?) -> OddsDetail?,
	tiers: () -> { RarityTierDef },
	-- v1.2 (N4): the player's current luck, used by roll() when its `luck` argument is nil.
	-- tableId nil = every table; a per-table value wins over the all-table one. Session only (not
	-- saved). Setting it re-sends that player's odds for luckDisclosed tables.
	-- HARD RULE: a PAID roll (Robux, or a cost in balance.paidCurrencies) whose effective luck is
	-- not 1 ERRORS unless the table has luckDisclosed = true and the player's client has already
	-- received odds computed with exactly that luck. Free rolls may use any luck.
	setLuck: (player: Player, luck: number, tableId: string?) -> (),
	getLuck: (player: Player, tableId: string?) -> number, -- 1 when never set
}

export type EconomyAPI = {
	grant: (player: Player, amount: number, reason: string, currency: string?) -> boolean,
	spend: (player: Player, amount: number, reason: string, currency: string?) -> boolean,
	balance: (player: Player, currency: string?) -> number,
	addIncomeSource: (player: Player, sourceId: string, perSec: number) -> (),
	removeIncomeSource: (player: Player, sourceId: string) -> (),
	addMultiplier: (player: Player, id: string, mult: number, expiresAt: number?, persist: boolean?) -> (),
	removeMultiplier: (player: Player, id: string) -> (),
	getMultiplier: (player: Player) -> number, -- combined multiplier (rebirth, upgrades, boosts, co-play)
	getRate: (player: Player) -> number, -- currency per second, after multipliers
}

export type InventoryAPI = {
	add: (player: Player, itemId: string, opts: InventoryAddOptions?) -> ItemInstance?,
	remove: (player: Player, uid: string, reason: string?) -> ItemInstance?,
	get: (player: Player, uid: string) -> ItemInstance?,
	list: (player: Player) -> { ItemInstance },
	count: (player: Player) -> number,
	cap: (player: Player) -> number,
	transfer: (from: Player, to: Player, uid: string, reason: string) -> (boolean, string?),
	canTrade: (player: Player) -> boolean,
	-- v1.2: gift an owned copy to ANY user (offline, other server, a stranger) through Core.Mail
	-- (needs the Mail module). The copy leaves the sender in the same Data.update that queues the
	-- message (outbox), so it is never duplicated or lost; the receiver gets the same instance
	-- (uid, mutation, meta, source) on delivery, or in their mailbox when their inventory is full.
	-- Reasons: "mail_off" | "not_loaded" | "same_player" | "not_owned" | "restricted_source" (copies
	-- from paid random sources, "paid:"/"paidcur:", can't be mailed: the receiver's policy is
	-- unknown) | "bad_target" | "failed".
	sendGift: (from: Player, toUserId: number, uid: string, reason: string?) -> (boolean, string?),
}

export type PlotAPI = {
	get: (player: Player) -> Model?,
	owner: (plot: Model) -> Player?,
	display: (player: Player, uid: string, slotId: string?) -> (boolean, string?),
	clearDisplay: (player: Player, uid: string) -> boolean,
	slots: (player: Player) -> { string },
	onAssigned: (handler: (player: Player, plot: Model) -> ()) -> Connection,
}

export type RebirthAPI = {
	canRebirth: (player: Player) -> boolean,
	rebirth: (player: Player) -> boolean,
	cost: (player: Player) -> number,
	multiplier: (player: Player) -> number,
}

export type UpgradesAPI = {
	level: (player: Player, upgradeId: string) -> number,
	cost: (player: Player, upgradeId: string) -> number?, -- nil = maxed / unknown
	purchase: (player: Player, upgradeId: string) -> (boolean, string?),
}

export type OfflineAPI = {
	onReturn: (handler: (player: Player, secondsAway: number) -> ()) -> Connection,
}

export type StreakAPI = {
	onDaily: (handler: (player: Player, streakDay: number) -> ()) -> Connection,
	get: (player: Player) -> StreakState,
}

export type FriendsAPI = {
	onCoPlay: (handler: (player: Player, friends: { Player }, kind: CoPlayKind) -> ()) -> Connection,
	friendsInServer: (player: Player) -> { Player },
}

export type EventsAPI = {
	schedule: (id: string, schedule: EventSchedule?, handler: (ctx: EventContext) -> ()) -> (),
	trigger: (id: string, by: Player?) -> boolean,
	isActive: (id: string) -> boolean,
	onEnded: (id: string, handler: (ctx: EventContext) -> ()) -> Connection,
}

export type ReceiptInfo = {
	PlayerId: number,
	PurchaseId: string,
	ProductId: number,
	CurrencySpent: number,
	PlaceIdWherePurchased: number,
}

-- Passed to a ProductHandler. Every grant helper writes into the handler's `data` (the same
-- transaction that records the receipt) and queues its signals/feedback until after the save.
export type PurchaseTx = {
	player: Player,
	receipt: ReceiptInfo,
	productName: string?, -- name in GameConfig.products.devProducts, if any
	policyKnown: boolean, -- Policy.isKnown(player) when the handler started
	paidRandomRestricted: boolean, -- Policy.paidRandomRestricted(player) (true while unknown)
	grant: (amount: number, currency: string?) -> boolean, -- Economy currency (Economy module)
	-- A fixed item. Source defaults to "paid:<productName or ProductId>" (kept on rebirth).
	addItem: (itemId: string, opts: InventoryAddOptions?) -> ItemInstance?, -- Inventory module
	-- A paid roll granted into the inventory (opts.paid/grant forced). Restricted players get
	-- info.ok == false, reason "restricted": grant them a fixed non-random fallback instead.
	-- luck nil = the player's current luck (Rarity.getLuck). This is a PAID roll: luck ~= 1 errors
	-- unless the table has luckDisclosed = true and the client has those odds (N4).
	roll: (tableId: string, luck: number?) -> (ItemDef?, RollInfo), -- Rarity + Inventory modules
	-- Abort without granting: nothing is saved, the receipt stays unprocessed (NotProcessedYet)
	-- and Roblox retries later (e.g. the policy lookup is still running). Does not return.
	retryLater: (reason: string?) -> (),
	-- Run fn once after the grant and receipt record committed (non-data side effects: VFX,
	-- messages). Runs exactly once per real grant; never for a declined/erroring handler.
	after: (fn: () -> ()) -> (),
}

-- Receipt-safe developer product handler (M4). Runs inside ONE Data.update together with the
-- receipt record: it must only change `data` (directly or through `tx`), must not yield (core
-- rejects it) and must not call other services' mutating APIs (Economy.grant, Inventory.add ...:
-- nested Data.update errors). Erroring = nothing granted, nothing recorded, NotProcessedYet.
-- PurchaseGranted is returned only after the save is confirmed, so a handler runs at most once
-- per PurchaseId even across server crashes.
export type ProductHandler = (data: PlayerData, receipt: ReceiptInfo, tx: PurchaseTx) -> ()

export type ShopAPI = {
	onProduct: (product: number | string, handler: ProductHandler) -> (),
	ownsPass: (player: Player, pass: number | string) -> boolean,
	onPassOwned: (pass: number | string, handler: (player: Player) -> ()) -> (),
}

export type PolicyAPI = {
	paidRandomRestricted: (player: Player) -> boolean, -- true (restricted) until the policy is known
	-- true once the policy lookup finished. Robux handlers: unknown -> return false (retry later);
	-- known restricted -> grant a non-random fallback.
	isKnown: (player: Player) -> boolean,
}

export type DataAPI = {
	get: (player: Player) -> PlayerData?, -- read-only view; never mutate outside update()
	update: (player: Player, fn: (data: PlayerData) -> ()) -> boolean, -- mutate inside fn
	onLoaded: (handler: (player: Player, data: PlayerData) -> ()) -> Connection, -- also fires for already-loaded players
	isLoaded: (player: Player) -> boolean,
	getGame: (player: Player) -> { [string]: any }?, -- PlayerData.game[gameId]
	updateGame: (player: Player, fn: (gameData: { [string]: any }) -> ()) -> boolean,
	-- Yields until the player's current data is committed to the DataStore (true) or the save
	-- failed / the player isn't loaded (false). Shop.ProcessReceipt waits on this before granting.
	saveAsync: (player: Player) -> boolean,
}

export type MailInfo = {
	id: string, -- idempotency key (MailAPI.send's `key`, or a generated GUID)
	kind: string,
	sentAt: number, -- unix seconds
	attempt: number, -- 1 on first delivery, +1 per retry
}

export type MailAPI = {
	-- Deliver a small message to any user, online or not (cross-server/offline gifts, bottle arrivals).
	-- `key` is the idempotency key: a second message with the same key to the same user is
	-- dropped once the first was processed. Default: a new GUID per call.
	send: (userId: number, kind: string, payload: { [string]: any }, key: string?) -> boolean,
	-- At-least-once delivery: a message is marked processed only when every handler for its kind
	-- returned without error. Handlers MUST be safe to run twice.
	--   nil/true -> delivered.
	--   false    -> "can't accept it now" (e.g. inventory full): the message moves to the player's
	--               mailbox (v1.2, N1) and waits there, with no time limit, for Mail.claim. Not a
	--               failure: never counted toward dead-lettering.
	--   error    -> failure: retried with backoff (GameConfig.mail), counted across sessions, then
	--               dead-lettered (PlayerData.mail.dead).
	-- Kinds starting with "core_" are reserved for core (e.g. Inventory.sendGift).
	onReceive: (
		kind: string,
		handler: (player: Player, payload: { [string]: any }, info: MailInfo) -> boolean?
	) -> Connection,
	-- v1.2 (N1): the player's mailbox, oldest first. Replicated as ReplicatedState.mailbox.
	pending: (player: Player) -> { MailboxEntry },
	-- v1.2 (N1): run the kind's handlers again for a held message. true = delivered and removed
	-- from the mailbox. Reasons: "not_loaded" | "not_found" | "busy" (a claim is running) |
	-- "still_held" (a handler returned false again) | "no_handler" | "error".
	claim: (player: Player, messageId: string) -> (boolean, string?),
}

-- Token bucket for a game remote: `rate` requests per second, up to `burst` at once.
export type RateLimitSpec = { rate: number, burst: number }

-- v1.2: games route their OWN Blink events through core's validated Net (foundation, always on).
export type NetAPI = {
	-- `event` is a server event from the game's generated Blink module (it has `.On`). Core owns
	-- the listener: it drops calls from players who left, rate-limits per player (`limit`), pcalls
	-- `handler` and logs errors. Blink checks wire types; the handler still validates ownership,
	-- ranges and game rules. One handler per eventName. Never use OnServerEvent in game code.
	handle: (
		eventName: string,
		event: any,
		limit: RateLimitSpec,
		handler: (player: Player, ...any) -> ()
	) -> (),
}

export type AnalyticsAPI = {
	funnel: (player: Player, step: string) -> (), -- logged once per player per step
	economy: (
		player: Player,
		flow: "Source" | "Sink",
		currency: string,
		amount: number,
		transactionType: string,
		sku: string?
	) -> (),
	custom: (player: Player, name: string, value: number?) -> (),
}

--------------------------------------------------------------------------------
-- Client namespaces
--------------------------------------------------------------------------------

-- Charm atom: call with no args to read, with a value/updater to write (client code should only read).
export type Atom<T> = (() -> T) & ((state: T | (T) -> T) -> T)

export type ReplicatedState = {
	loaded: boolean,
	-- The local player's data WITHOUT the server-only sections purchases, pity, funnel and mail
	-- (they are absent/empty on the client; M2).
	data: PlayerData?,
	ratePerSec: number,
	multiplier: number,
	paidRandomRestricted: boolean,
	activeEvents: { [string]: number }, -- eventId -> endsAt (unix seconds)
	plotName: string?, -- name of the player's plot Model in Workspace
	-- Server-computed odds of every player-facing rarity table (Rarity.getOddsDetail). Show these;
	-- never recompute odds on the client.
	odds: { [string]: OddsDetail }?,
	-- v1.2 (N1): the local player's mailbox (Mail.pending), oldest first. nil/empty = no items.
	mailbox: { MailboxEntry }?,
}

export type FeedbackAPI = {
	pop: (text: string, position: Vector3 | UDim2 | nil, rarity: RarityTier?) -> (),
	flash: (rarity: RarityTier) -> (),
	sound: (key: string) -> (),
	shake: (intensity: number?) -> (),
}

export type InputDevice = "KeyboardMouse" | "Touch" | "Gamepad"

export type InputBinding = {
	keys: { Enum.KeyCode }?,
	gamepad: { Enum.KeyCode }?,
	touchButton: boolean?, -- create an on-screen button on touch devices
	title: string?,
}

export type InputAPI = {
	device: () -> InputDevice,
	deviceChanged: Signal<InputDevice>,
	bind: (actionId: string, binding: InputBinding, handler: (state: "Began" | "Ended") -> ()) -> (),
	unbind: (actionId: string) -> (),
}

-- Thin client -> server requests. The server validates everything; these never assume success.
export type ActionsAPI = {
	display: (uid: string, slotId: string?) -> (),
	clearDisplay: (uid: string) -> (),
	rebirth: () -> (),
	upgrade: (upgradeId: string) -> (),
	roll: (tableId: string) -> (),
	gift: (toUserId: number, uid: string) -> (),
	triggerEvent: (eventId: string) -> (), -- admin only (server checks GameConfig.admins)
	funnel: (step: string) -> (), -- only AnalyticsConfig.clientSteps are accepted
	claimMail: (messageId: string) -> (), -- v1.2: Mail.claim for a mailbox entry (Mail module)
}

export type HudOptions = {
	nextGoal: (() -> string?)?, -- text for the "next goal" slot; re-evaluated when state changes
	showRate: boolean?,
	-- v1.2: tapping the mailbox badge (shown while the mailbox has items, Mail module). The game
	-- opens its own mailbox screen; without it the badge is shown but does nothing.
	onMailbox: (() -> ())?,
}

export type HudAPI = {
	mount: (opts: HudOptions?) -> (),
	unmount: () -> (),
}

export type ClientAPI = {
	state: Atom<ReplicatedState>,
	Feedback: FeedbackAPI,
	Input: InputAPI,
	Actions: ActionsAPI,
	Hud: HudAPI,
	onFeedbackEvent: (handler: (kind: string, text: string, rarity: RarityTier?) -> ()) -> Connection,
	-- v1.2 (N1): fires with the mailbox item count whenever it changes (and once on connect when
	-- the state is loaded).
	onMailbox: (handler: (count: number) -> ()) -> Connection,
}

--------------------------------------------------------------------------------
-- The facade
--------------------------------------------------------------------------------

-- The facade. Every namespace is a frozen table containing exactly the functions of its API type
-- (no init/start). Namespaces of modules not in GameConfig.modules exist but every call errors.
export type CoreAPI = {
	version: string,
	-- Once per side; a second call errors. Server: Core.start(Config, ServerConfig?).
	start: (gameConfig: GameConfig, serverConfig: ServerConfig?) -> (),
	isStarted: () -> boolean,
	config: () -> GameConfig,
	isEnabled: (moduleName: ModuleName) -> boolean, -- true for listed modules (valid after start)
	Signals: CoreSignals,
	-- server only (indexing these on the client errors)
	Items: ItemsAPI,
	Rarity: RarityAPI,
	Economy: EconomyAPI,
	Inventory: InventoryAPI,
	Plot: PlotAPI,
	Rebirth: RebirthAPI,
	Upgrades: UpgradesAPI,
	Offline: OfflineAPI,
	Streak: StreakAPI,
	Friends: FriendsAPI,
	Events: EventsAPI,
	Shop: ShopAPI,
	Policy: PolicyAPI,
	Data: DataAPI,
	Mail: MailAPI,
	Analytics: AnalyticsAPI,
	Net: NetAPI, -- v1.2: game remotes (foundation)
	-- client only
	Client: ClientAPI,
}

return Types
