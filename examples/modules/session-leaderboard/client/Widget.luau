--!strict
--[[
	HUD widget: this session's points, your best, and the top 3. Built from UI kit parts, which
	read the theme; the local player's row uses the module's theme token `leaderboardHighlight`.
	Tapping it opens the "Leaderboard" screen.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local ReactCharm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("ReactCharm"))
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any

local Definition = require(script.Parent.Parent:WaitForChild("module"))
local View = require(script.Parent.View)

local e = React.createElement

local function line(text: string, order: number, highlight: boolean): any
	return e("TextLabel", {
		Text = text,
		LayoutOrder = order,
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		FontFace = UI.Theme.font("body"),
		TextSize = UI.Theme.text.small,
		TextColor3 = if highlight then UI.Theme.color("leaderboardHighlight") else UI.Theme.color("text"),
	})
end

local function Widget()
	local slice = ReactCharm.useAtom(StudWork.use(Definition).state)
	local s = View.summary(slice, Players.LocalPlayer.UserId, 3)
	local children: { [string]: any } = {
		Layout = UI.Primitives.list(Enum.FillDirection.Vertical, 2),
		Session = line("Session " .. UI.Format.abbreviate(s.earned), 1, false),
		Best = line("Best " .. UI.Format.abbreviate(s.best), 2, false),
	}
	for _, row in s.rows do
		children["Row" .. row.rank] =
			line(`{row.rank}. {row.name}  {UI.Format.abbreviate(row.earned)}`, 2 + row.rank, row.isYou)
	end
	children.Open = e(UI.Button, {
		text = "Leaderboard",
		variant = "secondary",
		layoutOrder = 10,
		onActivated = function()
			UI.open("Leaderboard")
		end,
	})
	return e(UI.Panel, { automaticSize = Enum.AutomaticSize.XY }, children)
end

return Widget
