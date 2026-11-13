--!strict
--[[
	Quests demo server: boots StudWork. The game's logic, the world included, is its own module
	(modules/quests-demo, module-api.md §7 C4), which the framework adds by itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local ServerConfig = require(script.Parent.ServerConfig)

StudWork.start(Config, ServerConfig)
