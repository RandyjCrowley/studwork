--!strict
--[[
	The game's own module (module-api.md §7 C4, §6): the game acting as a module. The framework adds it
	to GameConfig.modules by itself. Rojo: this file -> ReplicatedStorage.GameModule.module, server/ ->
	ServerScriptService.Modules.CarryDemo. No save section: Carry and Movement keep no saves.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local KitDefs = ReplicatedStorage:WaitForChild("Modules")

return StudWork.defineModule({
	name = "CarryDemo",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "The carry kit's fixture game: carry objects to a zone, validated movement",
	dependsOn = {
		require(KitDefs:WaitForChild("Carry"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Movement"):WaitForChild("module")),
	},
	optional = {},
	server = "CarryDemo",
})
