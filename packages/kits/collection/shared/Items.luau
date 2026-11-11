--!strict
--[[
	Items module definition (kit: collection). core-v1.3.0: still a WRAPPER around the unchanged v1.2
	service at packages/kits/collection/server/Items, which now boots through StudWork.start: the
	compat bridge (packages/kits/compat/Bridge.luau, via ../server/ModuleServers.luau) runs its
	v1.2 init/start on a v1.2-shaped ctx (step 4b-IIa). Phase 1 replaces it with a real module.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

return StudWork.defineModule({
	name = "Items",
	version = "1.2.0",
	framework = "^1.3.0",
	description = "v1.2 Items service behind a defineModule wrapper (collection kit, compat bridge)",
})
