--!strict
--[[
	The game's own module (module-api.md §7 C4, §6): the game acting as a module. The framework
	adds it to GameConfig.modules by itself; its save section key is the gameId (the v1.2
	PlayerData.game[gameId] table). Rojo: this file -> ReplicatedStorage.GameModule.module,
	server/ -> ServerScriptService.Modules.<name>. dependsOn: the kit modules the game code uses
	(keep it in step with GameConfig.modules).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local KitDefs = ReplicatedStorage:WaitForChild("Modules")

return StudWork.defineModule({
	name = "OvC",
	version = "1.0.0",
	framework = "^1.3.0",
	description = "The sandbox game: touch the block, collect, earn; products, gifts and events",
	dependsOn = {
		require(KitDefs:WaitForChild("Rarity"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Inventory"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Economy"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Upgrades"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Rebirth"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Offline"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Streak"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Friends"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Mail"):WaitForChild("module")),
	},
	data = {
		key = GameConfig.gameId,
		version = 1,
		default = { blockTouches = 0 },
		replicate = { "blockTouches" },
	},
	server = "OvC",
})
