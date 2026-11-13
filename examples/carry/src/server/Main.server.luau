--!strict
--[[
	Carry fixture server: builds the world, then boots StudWork. The game's own module
	(examples/carry/modules/carry-demo) is added by the framework.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local ServerConfig = require(script.Parent.ServerConfig)
local World = require(script.Parent.World)

World.build()

StudWork.start(Config, ServerConfig)
