--!strict
--[[
	Boots StudWork on the client (added by `tools/adopt --init`, docs/framework/adopting.md §2):
	the framework HUD, toasts and every module's client part. The old game's UI keeps working next
	to it until the migration moves it (or keeps it, with its reason in studwork-legacy.json).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))

StudWork.start(Config)
