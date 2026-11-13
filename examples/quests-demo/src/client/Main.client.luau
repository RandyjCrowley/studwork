--!strict
--[[
	Quests demo client: StudWork.start(Config) and the framework HUD. Everything the Studio checks
	look at comes from the kit modules' own client parts: the Quests HUD button ("Quests.button")
	and tracker, the quest board (screen "Quests"), the claim toasts, and the Goals pill
	("Goals.goal"), world beam and edge arrow.

	The demo's one piece of glue: the second goal (`openBoard`, check { ack = true }) is
	acknowledged when the player opens the quest board while it is the current goal. The board is
	only ever opened by the player (the HUD button); nothing here opens a screen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local UI = require(ReplicatedStorage:WaitForChild("UI"))

local Modules = ReplicatedStorage:WaitForChild("Modules")
local GoalsDef = require(Modules:WaitForChild("Goals"):WaitForChild("module"))

local BOARD_SCREEN = "Quests"
local BOARD_GOAL = "openBoard"

StudWork.start(Config)
StudWork.Client.Hud.mount()

local goals = StudWork.use(GoalsDef)
local acked = false
UI.screens:subscribe(function()
	if acked or not UI.isOpen(BOARD_SCREEN) then
		return
	end
	local current = goals.goal()
	if current ~= nil and current.id == BOARD_GOAL then
		acked = true
		goals.actions.ackGoal(BOARD_GOAL)
	end
end)
