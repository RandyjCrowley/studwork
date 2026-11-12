--!strict
--[[
	The sandbox's own module (module-api.md §7 C4, §6): the game acting as a module. The framework
	adds it to GameConfig.modules by itself; its save section is the gameId ("sandbox", the v1.2
	PlayerData.game.sandbox table). Rojo: this file -> ReplicatedStorage.GameModule.module,
	server/ -> ServerScriptService.Modules.Sandbox.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local KitDefs = ReplicatedStorage:WaitForChild("Modules")

return StudWork.defineModule({
	name = "Sandbox",
	version = "1.0.0",
	framework = "^1.7.0",
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
	-- the v1.7.0 kits the demo hooks use (server/Demo<Module>.luau)
	optional = {
		require(KitDefs:WaitForChild("Leaderboards"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Badges"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Notifications"):WaitForChild("module")),
		require(KitDefs:WaitForChild("TextFilter"):WaitForChild("module")),
	},
	data = { key = "sandbox", version = 1, default = { blockTouches = 0 }, replicate = { "blockTouches" } },
	server = "Sandbox",
})
