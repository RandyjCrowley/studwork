--!strict
--[[
	Core server bootstrap. LEAD-OWNED. Required by the Core facade on the server.

	Init order matters only for init() (no cross-calls allowed there); start() runs in the same
	order. Data first (others react to Data.onLoaded), Plot before Replication-dependent UI,
	Replication last so it sees every service's initial setReplicated values.
]]

local RunService = game:GetService("RunService")

local Context = require(script.Context)
local Net = require(script.Net)
local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local services = {
	Data = require(script.Data),
	Items = require(script.Items),
	Policy = require(script.Policy),
	Rarity = require(script.Rarity),
	Inventory = require(script.Inventory),
	Economy = require(script.Economy),
	Upgrades = require(script.Upgrades),
	Rebirth = require(script.Rebirth),
	Offline = require(script.Offline),
	Streak = require(script.Streak),
	Friends = require(script.Friends),
	Events = require(script.Events),
	Shop = require(script.Shop),
	Analytics = require(script.Analytics),
	Mail = require(script.Mail),
	Plot = require(script.Plot),
}

local Replication = require(script.Replication)

local ORDER = {
	"Data",
	"Items",
	"Policy",
	"Rarity",
	"Inventory",
	"Economy",
	"Upgrades",
	"Rebirth",
	"Offline",
	"Streak",
	"Friends",
	"Events",
	"Shop",
	"Analytics",
	"Mail",
	"Plot",
}

local Server = {}
Server.services = services

function Server.start(core: Types.CoreAPI, config: Types.GameConfig)
	local ctx: Context.ServerContext = {
		config = config,
		services = (services :: any) :: Context.ServerServices,
		signals = core.Signals,
		net = Net :: any,
		setReplicated = function(player: Player, key: string, value: any)
			Replication.set(player, key, value)
		end,
		setReplicatedAll = function(key: string, value: any)
			Replication.setAll(key, value)
		end,
		isStudio = RunService:IsStudio(),
	}

	Replication.init(ctx)
	for _, name in ORDER do
		(services :: any)[name].init(ctx)
	end
	for _, name in ORDER do
		(services :: any)[name].start()
	end
	Replication.start()
	Net.start()
end

return Server
