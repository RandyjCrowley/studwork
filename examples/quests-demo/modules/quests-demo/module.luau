--!strict
--[[
	The quests demo's own module (module-api.md §7 C4, §6): the game acting as a module, added to
	GameConfig.modules by the framework. Rojo: this file -> ReplicatedStorage.GameModule.module,
	server/ -> ServerScriptService.Modules.QuestsDemo. Console commands are prefixed "questsdemo".

	Save section (the gameId): { coinTouches } (a counter the demo shows; quests keep their own).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local KitDefs = ReplicatedStorage:WaitForChild("Modules")

return StudWork.defineModule({
	name = "QuestsDemo",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "The quests kit's fixture game: coin spots, a guide, a board and a far tower",
	dependsOn = {
		require(KitDefs:WaitForChild("Items"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Rarity"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Inventory"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Economy"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Quests"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Goals"):WaitForChild("module")),
	},
	data = {
		key = GameConfig.gameId,
		version = 1,
		default = { coinTouches = 0 },
		replicate = { "coinTouches" },
	},
	server = "QuestsDemo",
})
