--!strict
--[[
	Core server bootstrap. LEAD-OWNED. Required by the Core facade on the server.

	Boots only the foundation (Data, Policy, Analytics, Events, Shop + Replication, Net, Console)
	and the modules enabled in GameConfig.modules. Order and the reasons for it: ModuleLoader.
	Disabled modules are erroring proxies in ctx.services (ModuleLoader.disabledProxy).
	Net is required here, so it listens to every client event from the moment CoreServer is
	required and queues (bounded) what arrives before Core.start (L3).
]]

local RunService = game:GetService("RunService")

local Console = require(script.Console)
local Context = require(script.Context)
local ModuleLoader = require(script.ModuleLoader)
local Net = require(script.Net)
local CoreShared = game:GetService("ReplicatedStorage"):WaitForChild("Core")
local Types = require(CoreShared:WaitForChild("Types"))

-- core-v1.3.0 Phase 0 step 5: the optional services moved to packages/kits/<kit>/server
-- (Rojo: ServerScriptService.Kits.<Kit>). Their internals are unchanged v1.2 code and this
-- facade still owns their init/start; the kit modules' defineModule wrappers are dormant.
local Kits = game:GetService("ServerScriptService"):WaitForChild("Kits")

local services = {
	Data = require(script.Data),
	Items = require(Kits:WaitForChild("Collection"):WaitForChild("Items")),
	Policy = require(script.Policy),
	Rarity = require(Kits:WaitForChild("Collection"):WaitForChild("Rarity")),
	Inventory = require(Kits:WaitForChild("Collection"):WaitForChild("Inventory")),
	Economy = require(Kits:WaitForChild("Economy"):WaitForChild("Economy")),
	Upgrades = require(Kits:WaitForChild("Economy"):WaitForChild("Upgrades")),
	Rebirth = require(Kits:WaitForChild("Economy"):WaitForChild("Rebirth")),
	Offline = require(Kits:WaitForChild("Economy"):WaitForChild("Offline")),
	Streak = require(Kits:WaitForChild("Engagement"):WaitForChild("Streak")),
	Friends = require(Kits:WaitForChild("Social"):WaitForChild("Friends")),
	Events = require(script.Events),
	Shop = require(script.Shop),
	Analytics = require(script.Analytics),
	Mail = require(Kits:WaitForChild("Social"):WaitForChild("Mail")),
	Plot = require(Kits:WaitForChild("Base"):WaitForChild("Plot")),
	Net = require(script.GameNet), -- v1.2: Core.Net (game remotes); core's own Net is ctx.net
}

local Replication = require(script.Replication)

local Server = {}
Server.services = services

local booted = false

function Server.start(
	core: Types.CoreAPI,
	config: Types.GameConfig,
	serverConfig: Types.ServerConfig,
	moduleOrder: { string }
)
	assert(not booted, "[Core] Core.start was already called (call it once per side)")
	booted = true
	-- Defensive: ConfigValidate already rejected bad lists with the same messages.
	local plan, problem = ModuleLoader.plan(moduleOrder)
	if plan == nil then
		error("[Core] invalid GameConfig.modules:\n" .. tostring(problem), 0)
	end
	local active = ModuleLoader.services(services, plan)
	local ctx: Context.ServerContext = {
		config = config,
		services = (active :: any) :: Context.ServerServices,
		signals = core.Signals,
		net = Net :: any,
		setReplicated = function(player: Player, key: string, value: any)
			Replication.set(player, key, value)
		end,
		setReplicatedAll = function(key: string, value: any)
			Replication.setAll(key, value)
		end,
		sentReplicated = function(player: Player, key: string): any
			return Replication.sent(player, key)
		end,
		console = Console,
		isStudio = RunService:IsStudio(),
		serverConfig = serverConfig,
		modules = moduleOrder,
		isEnabled = ModuleLoader.isEnabledFn(moduleOrder),
	}

	Replication.init(ctx)
	for _, name in plan do
		(services :: any)[name].init(ctx)
	end
	for _, name in plan do
		(services :: any)[name].start()
	end
	Replication.start()
	Console.register("net", "net: dropped early / handler-less client request counts", Net.stats)
	Console.register("modules", "modules: enabled optional modules in boot order", function()
		return if #moduleOrder == 0 then "foundation only" else table.concat(moduleOrder, ", ")
	end)
	Net.start()
	Console.start()
end

return Server
