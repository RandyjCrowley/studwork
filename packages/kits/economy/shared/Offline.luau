--!strict
--[[
	Offline module definition (kit: economy). core-v1.3.0: still a WRAPPER around the unchanged v1.2
	service at packages/kits/economy/server/Offline, which now boots through StudWork.start: the
	compat bridge (packages/kits/compat/Bridge.luau, via ../server/ModuleServers.luau) runs its
	v1.2 init/start on a v1.2-shaped ctx (step 4b-IIa). Phase 1 replaces it with a real module.
	config: the v1.2 `balance` keys this module owns, unchanged (compat/shared/V12Config.luau
	maps them back for the v1.2 code). Loose schemas: the v1.2 ConfigValidate still validates
	the values at boot.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

return StudWork.defineModule({
	name = "Offline",
	version = "1.2.0",
	framework = "^1.3.0",
	description = "v1.2 Offline service behind a defineModule wrapper (economy kit, compat bridge)",
	config = {
		schema = { offline = "table?" },
		defaults = {},
	},
})
