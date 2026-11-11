--!strict
--[[
	Foundation-only server: boots StudWork with modules = {} (plus the game's own module, which
	the framework adds). Expected output: "[foundation-only] boot ok", then on join the
	FoundationOnly module's "Rebirth.rebirth -> ok=false ... Rebirth is not enabled in GameConfig.modules".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))

StudWork.start(Config, { admins = {} })

print("[foundation-only] boot ok")
