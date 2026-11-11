--!strict
--[[
	Plot module definition (kit: base). core-v1.3.0: still a WRAPPER around the unchanged v1.2
	service at packages/kits/base/server/Plot, which now boots through StudWork.start: the
	compat bridge (packages/kits/compat/Bridge.luau, via ../server/ModuleServers.luau) runs its
	v1.2 init/start on a v1.2-shaped ctx (step 4b-IIa). Phase 1 replaces it with a real module.
	config: the v1.2 `balance` keys this module owns, unchanged (compat/shared/V12Config.luau
	maps them back for the v1.2 code). Loose schemas: the v1.2 ConfigValidate still validates
	the values at boot.
	data: section 'plot' = this module's v1.2 PlayerData fields with their v1.2 defaults
	(FrameworkSection.V12_MAP); replicate = the fields v1.2 replicated to the owning client.
	client: its v1.2 client action(s), served by ../shared/ModuleClients.luau.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Inventory =
	require(ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Collection"):WaitForChild("Inventory"))

return StudWork.defineModule({
	name = "Plot",
	version = "1.2.0",
	framework = "^1.3.0",
	description = "v1.2 Plot service behind a defineModule wrapper (base kit, compat bridge)",
	dependsOn = { Inventory },
	config = {
		schema = { plot = "table?", assetsFolderName = "string?" },
		defaults = {},
	},
	data = { key = "plot", version = 1, default = { displayed = {} }, replicate = { "displayed" } },
	client = "Plot",
})
