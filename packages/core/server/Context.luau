--!strict
--[[
	Server-side internal context handed to every core service in init(ctx). LEAD-OWNED.

	Service module shape (every folder under core/server/<Service>/init.luau):
		local Service = {}
		function Service.init(ctx: Context.ServerContext) ... end -- store ctx; no yielding, no cross-calls
		function Service.start() ... end                         -- connect events, start loops
		-- public functions exactly as declared in core/shared/Types.luau (<Service>API)
		return Service

	Services call each other ONLY through ctx.services.<Name>.<public fn> (the frozen API), never
	through private fields, so a stub can be swapped for the real service without touching callers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Types"))

export type ServerServices = {
	Data: Types.DataAPI,
	Items: Types.ItemsAPI,
	Policy: Types.PolicyAPI,
	Rarity: Types.RarityAPI,
	Inventory: Types.InventoryAPI,
	Economy: Types.EconomyAPI,
	Upgrades: Types.UpgradesAPI,
	Rebirth: Types.RebirthAPI,
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
}

return {}
