--!strict
--[[
	The game's own module (module-api.md §7 C4, §6): the game acting as a module. The framework
	adds it to GameConfig.modules by itself; its save section key is the gameId (the v1.2
	PlayerData.game[gameId] table). Rojo: this file -> ReplicatedStorage.GameModule.module,
	server/ -> ServerScriptService.Modules.<name>.

	dependsOn vs optional (module-api.md §3, §5). tools/new-game and new-project --modules list
	every chosen kit in GameConfig.modules; here the core kits go in dependsOn and the chosen
	Leaderboards, Badges, Notifications and TextFilter stay in optional. Both give ctx.deps[Kit]:
	  - dependsOn: boot fails if the kit is missing from GameConfig.modules, and the kit's init
	    runs before this module's (an ordering edge).
	  - optional: ctx.deps[Kit] works while the game lists the kit and errors when it is off; it
	    is not an ordering edge, so call it from start or later, and guard with ctx.isEnabled(Kit)
	    if the game may drop the kit. Move a kit up to dependsOn when the game can't run without
	    it or this module's init needs it.
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
