--!strict
--[[
	Boots StudWork on the server (added by `tools/adopt --init`, docs/framework/adopting.md §2).
	The game's logic is its own module (modules/<gameId>/), which the framework adds by itself;
	GameConfig is src/shared/Config (mapped as ReplicatedStorage.Game.Config).
	StudWork saves to its OWN store (PlayerData_<gameId>); old saves come over read-only through
	ctx.data.importLegacy, so booting it next to the old scripts never touches the old store.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local ServerConfig = require(script.Parent.ServerConfig)

StudWork.start(Config, ServerConfig)
