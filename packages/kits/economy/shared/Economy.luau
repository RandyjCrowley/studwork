--!strict
--[[
	Economy module definition (kit: economy). core-v1.3.0: still a WRAPPER around the unchanged v1.2
	service at packages/kits/economy/server/Economy, which now boots through StudWork.start: the
	compat bridge (packages/kits/compat/Bridge.luau, via ../server/ModuleServers.luau) runs its
	v1.2 init/start on a v1.2-shaped ctx (step 4b-IIa). Phase 1 replaces it with a real module.
	config: the v1.2 `balance` keys this module owns, unchanged (compat/shared/V12Config.luau
	maps them back for the v1.2 code). Loose schemas: the v1.2 ConfigValidate still validates
	the values at boot.
	data: section 'economy' = this module's v1.2 PlayerData fields with their v1.2 defaults
	(FrameworkSection.V12_MAP); replicate = the fields v1.2 replicated to the owning client.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

return StudWork.defineModule({
	name = "Economy",
	version = "1.2.0",
	framework = "^1.3.0",
	description = "v1.2 Economy service behind a defineModule wrapper (economy kit, compat bridge)",
	config = {
		schema = {
			primaryCurrency = "string",
			startingCurrency = "{[string]: number}?",
			income = "table?",
			multiplierStacking = "string?",
		},
		defaults = { primaryCurrency = "Coins" },
	},
	data = {
		key = "economy",
		version = 1,
		default = { currency = {}, multipliers = {} },
		replicate = { "currency", "multipliers" },
	},
	itemFields = { item = { economy = { incomePerSec = "number?" } } },
})
