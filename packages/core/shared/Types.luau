--!strict
--[[
	Core public interface. FROZEN at tag core-contract-v0.

	ADDITIVE ONLY: new fields/functions/types may be added; nothing is ever renamed or removed.
	Deprecate instead (keep it working, mark it `-- @deprecated <why, replacement>`).
	Every change is recorded in packages/core/CHANGELOG.md.

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
}

-- One owned copy of an item. Saved in PlayerData.inventory keyed by uid.
export type ItemInstance = {
	uid: string, -- globally unique (GUID) so items can move between players
	itemId: string,
	mutation: string?, -- Mutation.id
	acquiredAt: number, -- unix seconds (os.time())
	source: string?, -- how this copy was obtained ("roll", "gift", ...)
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
	startingCurrency: { [string]: number }?,
	starterItems: { string }?, -- item ids granted on first join (and displayed if possible)
	income: IncomeConfig,
	multiplierStacking: "multiply" | "add"?, -- default "multiply"
	inventory: { cap: number },
	rarityTables: { [string]: RarityTableConfig },
	mutations: { Mutation }?,
	upgrades: { [string]: UpgradeConfig }?,
	rebirth: RebirthConfig,
	offline: OfflineConfig,
	streak: StreakConfig,
	friends: FriendsConfig,
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

export type AnalyticsConfig = {
	funnel: { string }, -- ordered onboarding steps; index = step number sent to AnalyticsService
	clientSteps: { string }?, -- steps the client may report (UI-only steps); everything else is server-only
}

export type PaletteOverrides = { [string]: string } -- palette key -> hex

export type GameConfig = {
	gameId: string, -- stable key: PlayerData.game[gameId], DataStore name suffix, remote scope
	items: { ItemDef },
	balance: BalanceConfig,
	products: ProductsConfig,
	events: EventsConfig,
	palette: PaletteOverrides?,
	admins: { number }?, -- user ids allowed to trigger events / admin commands
	data: GameDataConfig?,
	analytics: AnalyticsConfig?,
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

export type RarityAPI = {
	roll: (tableId: string, player: Player, luck: number?, opts: RollOptions?) -> (ItemDef?, RollInfo),
	getOdds: (tableId: string, luck: number?) -> { [string]: number }, -- itemId -> probability (sums to 1)
	tiers: () -> { RarityTierDef },
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

export type ShopAPI = {
	-- handler returns true when the product was granted. Core records the receipt before returning
	-- PurchaseGranted, so the handler runs at most once per PurchaseId.
	onProduct: (product: number | string, handler: (player: Player, receipt: ReceiptInfo) -> boolean) -> (),
	ownsPass: (player: Player, pass: number | string) -> boolean,
	onPassOwned: (pass: number | string, handler: (player: Player) -> ()) -> (),
}

export type PolicyAPI = {
	paidRandomRestricted: (player: Player) -> boolean, -- true (restricted) until the policy is known
}

export type DataAPI = {
	get: (player: Player) -> PlayerData?, -- read-only view; never mutate outside update()
	update: (player: Player, fn: (data: PlayerData) -> ()) -> boolean, -- mutate inside fn
	onLoaded: (handler: (player: Player, data: PlayerData) -> ()) -> Connection, -- also fires for already-loaded players
	isLoaded: (player: Player) -> boolean,
	getGame: (player: Player) -> { [string]: any }?, -- PlayerData.game[gameId]
	updateGame: (player: Player, fn: (gameData: { [string]: any }) -> ()) -> boolean,
}

export type MailAPI = {
	-- Deliver a small message to any user, online or not (cross-server/offline gifts, bottle arrivals).
	send: (userId: number, kind: string, payload: { [string]: any }) -> boolean,
	onReceive: (kind: string, handler: (player: Player, payload: { [string]: any }) -> ()) -> Connection,
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
	data: PlayerData?,
	ratePerSec: number,
	multiplier: number,
	paidRandomRestricted: boolean,
	activeEvents: { [string]: number }, -- eventId -> endsAt (unix seconds)
	plotName: string?, -- name of the player's plot Model in Workspace
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
}

export type HudOptions = {
	nextGoal: (() -> string?)?, -- text for the "next goal" slot; re-evaluated when state changes
	showRate: boolean?,
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
}

--------------------------------------------------------------------------------
-- The facade
--------------------------------------------------------------------------------

export type CoreAPI = {
	version: string,
	start: (gameConfig: GameConfig) -> (),
	isStarted: () -> boolean,
	config: () -> GameConfig,
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
	-- client only
	Client: ClientAPI,
}

return Types
