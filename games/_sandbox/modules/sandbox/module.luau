--!strict
--[[
	The sandbox's own module (module-api.md §7 C4, §6): the game acting as a module. The framework
	adds it to GameConfig.modules by itself; its save section is the gameId ("sandbox", the v1.2
	PlayerData.game.sandbox table). Rojo: this file -> ReplicatedStorage.GameModule.module,
	server/ -> ServerScriptService.Modules.Sandbox.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
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
	data = { key = "sandbox", version = 1, default = { blockTouches = 0 }, replicate = { "blockTouches" } },
	server = "Sandbox",
})
