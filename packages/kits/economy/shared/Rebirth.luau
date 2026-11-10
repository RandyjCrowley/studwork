--!strict
--[[
	Rebirth module definition (kit: economy). core-v1.3.0 Phase 0 step 5: a THIN wrapper, not a rewrite
	(module-api.md §5 step 5). The implementation is still the unchanged v1.2 service at
	packages/kits/economy/server/Rebirth, booted by the v1.2 packages/core facade (Core.start) during this
	step; ../server/ModuleServers.luau exposes it as this module's server.api for the framework
	loader. Config schema, the real data section (default, migrations, replicate) and optional
	dependencies are Phase 1 work; data.key follows decisions.md (Phase 0 step 4, decision 2).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Economy = require(script.Parent.Economy)

return StudWork.defineModule({
	name = "Rebirth",
	version = "1.2.0",
	framework = "^1.3.0",
	description = "v1.2 Rebirth service behind a thin defineModule wrapper (economy kit)",
	dependsOn = { Economy },
	data = { key = "rebirth", version = 1, default = {}, replicate = false },
})
