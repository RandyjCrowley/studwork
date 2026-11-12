--!strict
--[[
	The game's own module (module-api.md §7 C4, §6): the game acting as a module. The framework
	adds it to GameConfig.modules by itself; its save section key is the gameId (the v1.2
	PlayerData.game[gameId] table). Rojo: this file -> ReplicatedStorage.GameModule.module,
	server/ -> ServerScriptService.Modules.<name>.

	dependsOn vs optional (module-api.md §3, §5):
	  - dependsOn: kit modules the game code calls unconditionally (ctx.deps[Kit]). Boot fails if
	    one is missing from GameConfig.modules, so keep it in step with that list (tools/new-game
	    --modules writes both).
	  - optional: kit modules the code uses only when the game lists them: guard each use with
	    ctx.isEnabled(Kit); ctx.deps[Kit] errors when the kit is off. To use one unconditionally
	    (say Leaderboards), list it in GameConfig.modules and move it from optional to dependsOn.
	The console commands this module registers are prefixed with its lower-case name.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local KitDefs = ReplicatedStorage:WaitForChild("Modules")

return StudWork.defineModule({
	name = "Sandbox",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "This game's own module: touch the block, collect, earn; products, gifts and events",
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
	-- kit modules used only when the game lists them (guard with ctx.isEnabled); move one up to
	-- dependsOn once the game depends on it
	optional = {
		require(KitDefs:WaitForChild("Leaderboards"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Badges"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Notifications"):WaitForChild("module")),
		require(KitDefs:WaitForChild("TextFilter"):WaitForChild("module")),
	},
	data = {
		key = GameConfig.gameId,
		version = 1,
		default = { blockTouches = 0 },
		replicate = { "blockTouches" },
	},
	server = "Sandbox",
})
