--!strict
--[[
	Foundation-only test config (core-v1.3.0 shape): no kit modules, no items. Proves StudWork
	boots with just the framework (Data, Policy, Analytics, Events, Shop, Net, Replication,
	Compliance, Console) plus the game's own module (foundation-only/modules/foundationonly), and
	that a module that isn't enabled errors with a clear message.
]]

local Config = {
	gameId = "foundationonly",
	modules = {} :: { any },
	items = {},
	products = { passes = {}, devProducts = {} },
	events = {
		Ping = { durationSec = 30 },
	},
	analytics = {
		funnel = { "Joined" },
		clientSteps = {},
	},
}

return Config
