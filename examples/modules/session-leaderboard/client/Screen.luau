--!strict
--[[
	The "Leaderboard" screen: the full top list. Registered by client/init.luau with
	UI.registerScreen("Leaderboard", Screen); a game replaces it by registering its own screen
	under the same name (module-api.md §13).
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

export type Props = { onClose: (() -> ())? }

local function Screen(props: Props)
	local slice = ReactCharm.useAtom(StudWork.use(Definition).state)
	local s = View.summary(slice, Players.LocalPlayer.UserId)
	local rows: { [string]: any } = {
		Summary = e("TextLabel", {
			Text = `This session {UI.Format.abbreviate(s.earned)}  ·  Best {UI.Format.abbreviate(s.best)}`,
			LayoutOrder = 0,
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.XY,
			FontFace = UI.Theme.font("bold"),
			TextSize = UI.Theme.text.body,
			TextColor3 = UI.Theme.color("text"),
		}),
	}
	for _, row in s.rows do
		rows["Row" .. row.rank] = e("TextLabel", {
			Text = `{row.rank}. {row.name}  {UI.Format.abbreviate(row.earned)}`,
			LayoutOrder = row.rank,
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.XY,
			FontFace = UI.Theme.font("body"),
			TextSize = UI.Theme.text.body,
			TextColor3 = if row.isYou then UI.Theme.color("leaderboardHighlight") else UI.Theme.color("text"),
		})
	end
	return e(UI.Modal, { open = true, title = "Session leaderboard", onClose = props.onClose }, rows)
end

return Screen
