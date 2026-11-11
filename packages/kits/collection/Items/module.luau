--!strict
--[[
	Items module definition (kit: collection; module-api.md §2, §12). Server part:
	./server/init.luau (ServerScriptService.Modules.Items).

	The item catalog: GameConfig.items, validated once at boot (base ItemDef fields
	{ id, name, rarity, model, icon, tags, source, keepOnRebirth } plus every enabled module's
	namespaced itemFields, e.g. Economy's item.economy.incomePerSec). There is no registration
	after boot (core-v1.3.0 Breaking). Items also serves the MUTATION defs (api.mutation /
	mutations); their config lives in config.Rarity.mutations (Rarity hands it over at init), and
	mutation effects are namespaced fields added by other kits (mutation.economy.incomeMultiplier).

	No config, no save section, no client part.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

return StudWork.defineModule({
	name = "Items",
	version = "1.3.0",
	framework = "^1.3.0",
	description = "Item catalog (GameConfig.items) and mutation defs (collection kit)",
})
