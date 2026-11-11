--!strict
--[[
	SessionLeaderboard client part (module-api.md §9, §10, §13). Public API only.
	  start: registers the "Leaderboard" screen (UI.registerScreen; a game replaces it by
	         registering its own "Leaderboard") and the HUD widget "SessionLeaderboard.top" in the
	         "right" slot (a game hides it with client.hud.widgets = { ["SessionLeaderboard.top"] = false }).
	  api:   summary() -> View.Summary for the local player; open() opens the screen.
	StudWork.use(SessionLeaderboard) on the client also carries state() (this module's replicated
	slice) and actions (none: the module takes no client input).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
-- the screen registry and HUD widget slots: module-api.md §13 (packages/ui)
local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any

local Definition = require(script.Parent:WaitForChild("module"))
local Screen = require(script.Screen)
local View = require(script.View)
local Widget = require(script.Widget)

local SessionLeaderboardClient = {}

function SessionLeaderboardClient.start(_ctx: any)
	UI.registerScreen("Leaderboard", Screen)
	-- HUD widgets (§13 "Modules contribute widgets"): the registration call is the UI owner's;
	-- skipped while the UI package doesn't offer it yet.
	if type(UI.registerWidget) == "function" then
		UI.registerWidget("SessionLeaderboard.top", { slot = "right", component = Widget })
	end
end

SessionLeaderboardClient.api = {
	summary = function(): View.Summary
		return View.summary(StudWork.use(Definition).state(), Players.LocalPlayer.UserId)
	end,
	open = function()
		UI.open("Leaderboard")
	end,
}

return SessionLeaderboardClient
