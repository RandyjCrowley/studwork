--!strict
--[[
	Foundation-only test config: no optional modules, no items, no module balance sections.
	Proves Core boots with just the foundation (Data, Policy, Analytics, Events, Shop + Net,
	Replication, Console) and that module calls error with a clear message.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Config: Types.GameConfig = {
	gameId = "foundationonly",
	modules = {},
	items = {},
	balance = {
		primaryCurrency = "Coins",
	},
	products = { passes = {}, devProducts = {} },
	events = {
		Ping = { durationSec = 30 },
	},
	data = {
		defaults = { joins = 0 },
		version = 1,
	},
	analytics = {
		funnel = { "Joined" },
		clientSteps = {},
	},
}

return Config
