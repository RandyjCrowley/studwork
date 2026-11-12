--!strict
--[[
	Boots StudWork on the server (added by `tools/adopt --init`, docs/framework/adopting.md §2).
	The game's logic is its own module (modules/<gameId>/), which the framework adds by itself;
	GameConfig is src/shared/Config (mapped as ReplicatedStorage.Game.Config).
	StudWork saves to its OWN store (PlayerData_<gameId>); old saves come over read-only through
	ctx.data.importLegacy, so booting it next to the old scripts never touches the old store.
	(v1.6.1) studwork-legacy.json is mapped next to this script as the JSON ModuleScript LegacyList;
	it is passed as ServerConfig.legacyList (a live server warns while old code is still listed).
	Projects adopted before v1.6.1 have no LegacyList: then nothing is passed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local ServerConfig = require(script.Parent.ServerConfig)

local legacyListModule = script.Parent:FindFirstChild("LegacyList")
if legacyListModule and legacyListModule:IsA("ModuleScript") then
	local ok, legacyList = pcall(require :: any, legacyListModule)
	if ok and type(legacyList) == "table" then
		(ServerConfig :: any).legacyList = legacyList
	end
end

StudWork.start(Config, ServerConfig)
