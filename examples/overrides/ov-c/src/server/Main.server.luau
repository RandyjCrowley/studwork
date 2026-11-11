--!strict
--[[
	Sandbox server: builds the world, then boots StudWork. The game's logic is its own module
	(examples/sandbox/modules/sandbox, module-api.md §7 C4), which the framework adds by itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local ServerConfig = require(script.Parent.ServerConfig)
local World = require(script.Parent.World)

World.build()

StudWork.start(Config, ServerConfig)
