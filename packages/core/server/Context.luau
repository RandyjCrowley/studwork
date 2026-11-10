--!strict
--[[
	Server-side internal context handed to every core service in init(ctx). LEAD-OWNED.

	Service module shape (every folder under core/server/<Service>/init.luau):
		local Service = {}
		function Service.init(ctx: Context.ServerContext) ... end -- store ctx; no yielding, no cross-calls
		function Service.start() ... end                         -- connect events, start loops
		-- public functions exactly as declared in core/shared/Types.luau (<Service>API)
		return Service

	Services call each other ONLY through ctx.services.<Name>.<public fn> (the frozen API) or the
	ctx-only internals typed below (*Internal), never through private fields or another
	service's private modules, and never write another module's PlayerData sections.

	Data.update contract (core-contract-v1.1):
	  - fn runs against a working copy; the change is committed only when fn returns without
	    error (an error discards every write made in fn, then re-raises with a traceback). L6.
	  - fn must not yield (Data errors and discards the change).
	  - A Data.update for a player inside another Data.update for the SAME player errors
	    ("nested Data.update"): open one transaction and use *Into functions instead.
	  - Only the sections fn touched change identity; untouched sections keep their table
	    references, and sectionVersion() moves only for touched sections.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Types"))

-- A data transaction: the working copy inside ONE Data.update plus a queue of side effects.
-- `*Into` functions write only into tx.data and queue signals/feedback/analytics with tx.after;
-- whoever opened the transaction runs the queue after it committed (Shop: after the save).
export type Tx = {
	player: Player,
	data: Types.PlayerData,
	after: (fn: () -> ()) -> (),
}

-- Internal (ctx-only) functions on top of the public APIs. Never exposed on the Core facade.
export type DataInternal = Types.DataAPI & {
	-- Increments every time a committed Data.update changed that top-level PlayerData key
	-- ("currency", "inventory", ...). Replication copies only sections whose version moved.
	sectionVersion: (player: Player, section: string) -> number,
}

export type EconomyInternal = Types.EconomyAPI & {
	grantInto: (tx: Tx, amount: number, reason: string, currency: string?) -> boolean,
}

export type InventoryInternal = Types.InventoryAPI & {
	addInto: (tx: Tx, itemId: string, opts: Types.InventoryAddOptions?) -> Types.ItemInstance?,
}

export type RarityInternal = Types.RarityAPI & {
	rollInto: (
		tx: Tx,
		tableId: string,
		luck: number?,
		opts: Types.RollOptions?
	) -> (Types.ItemDef?, Types.RollInfo),
}

export type RebirthInternal = Types.RebirthAPI & {
	-- Register a step that runs INSIDE Rebirth's single Data.update (after currency/inventory
	-- resets, before the count increments). Upgrades resets levels, Plot drops displayed slots.
	-- fn must only touch its own module's sections of `data`.
	addResetStep: (id: string, fn: (data: Types.PlayerData, player: Player) -> ()) -> (),
}

-- ctx.services: foundation services always; a disabled module is a proxy whose every field
-- errors "<Name> is not enabled in GameConfig.modules". Check ctx.isEnabled(name) before
-- calling an OPTIONAL dependency (Modules.SPECS[...].optional).
export type ServerServices = {
	Data: DataInternal,
	Items: Types.ItemsAPI,
	Policy: Types.PolicyAPI,
	Rarity: RarityInternal,
	Inventory: InventoryInternal,
	Economy: EconomyInternal,
	Upgrades: Types.UpgradesAPI,
	Rebirth: RebirthInternal,
	Offline: Types.OfflineAPI,
	Streak: Types.StreakAPI,
	Friends: Types.FriendsAPI,
	Events: Types.EventsAPI,
	Shop: Types.ShopAPI,
	Analytics: Types.AnalyticsAPI,
	Mail: Types.MailAPI,
	Plot: Types.PlotAPI,
}

export type NetAPI = {
	-- Register the single handler for a client -> server event. Net has already rate-limited the
	-- call and Blink has checked wire types/ranges; the handler must still check ownership/rules.
	handle: (eventName: string, handler: (player: Player, ...any) -> ()) -> (),
	-- Generated Blink server module (fire server -> client events through this).
	events: any,
	-- Send a cosmetic feedback message to one player.
	feedback: (player: Player, kind: string, text: string, rarity: string?, position: Vector3?) -> (),
}

export type ConsoleAPI = {
	-- Register a console command (Studio command bar / MCP / admin): fn(...) -> result string.
	register: (name: string, help: string, fn: (...any) -> string?) -> (),
}

export type ServerContext = {
	config: Types.GameConfig,
	services: ServerServices,
	signals: Types.CoreSignals,
	net: NetAPI,
	-- Replication hook (agent G): extra non-PlayerData state for ReplicatedState
	-- (ratePerSec, multiplier, paidRandomRestricted, activeEvents, plotName). Services call
	-- ctx.setReplicated(player, key, value) and Replication ships it.
	setReplicated: (player: Player, key: string, value: any) -> (),
	setReplicatedAll: (key: string, value: any) -> (), -- same value for every player (activeEvents)
	console: ConsoleAPI,
	isStudio: boolean,
	-- Modules (packages/core/shared/Modules.luau)
	serverConfig: Types.ServerConfig, -- Core.start's second argument ({} when omitted)
	modules: { string }, -- enabled optional modules in boot order
	isEnabled: (name: string) -> boolean, -- foundation names -> true; modules -> listed?
}

return {}
