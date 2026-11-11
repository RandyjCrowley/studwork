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
local KitDefs = ReplicatedStorage:WaitForChild("Kits")
local Collection = KitDefs:WaitForChild("Collection")
local EconomyKit = KitDefs:WaitForChild("Economy")
local Social = KitDefs:WaitForChild("Social")
local Engagement = KitDefs:WaitForChild("Engagement")

return StudWork.defineModule({
	name = "Sandbox",
	version = "1.0.0",
	framework = "^1.3.0",
	description = "The sandbox game: touch the block, collect, earn; products, gifts and events",
	dependsOn = {
		require(Collection:WaitForChild("Rarity")),
		require(Collection:WaitForChild("Inventory")),
		require(EconomyKit:WaitForChild("Economy")),
		require(EconomyKit:WaitForChild("Upgrades")),
		require(EconomyKit:WaitForChild("Rebirth")),
		require(EconomyKit:WaitForChild("Offline")),
		require(Engagement:WaitForChild("Streak")),
		require(Social:WaitForChild("Friends")),
		require(Social:WaitForChild("Mail")),
	},
	data = {
		key = GameConfig.gameId,
		version = 1,
		default = { blockTouches = 0 },
		replicate = { "blockTouches" },
	},
	server = "Sandbox",
})
