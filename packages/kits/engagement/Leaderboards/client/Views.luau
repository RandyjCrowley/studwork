--!strict
--[[
	Leaderboards client views (React): the "Leaderboards" screen (a tab per board) and the single
	board view `attach` mounts in the world. Loaded lazily by client/init.luau, so requiring the
	module in a test or on a server never needs React. Every label is a string key through UI.text
	(no English here); the player's own value and rank come from the replicated `mine` and the rows
	from the shared top N, both read-only.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages:WaitForChild("React")) :: any
local ReactCharm = require(Packages:WaitForChild("ReactCharm")) :: any
local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
local State = require(script.Parent.State)

local e = React.createElement

local Views = {}

local function rawState(): any
	local StudWork = require(ReplicatedStorage:WaitForChild("Framework")) :: any
	return StudWork.Client.state()
end

local function selfUserId(): number?
	local player = Players.LocalPlayer
	return if player then player.UserId else nil
end

-- One board as a UI.Leaderboard. props: boardId, format?, title? (a string key), size?, layoutOrder?
function Views.Board(props: any): any
	local entry = ReactCharm.useAtom(function(): any
		return State.entry(rawState(), props.boardId)
	end)
	local mine = ReactCharm.useAtom(function(): any
		return State.mine(rawState(), props.boardId)
	end)
	local fallback = UI.useText("Leaderboards.title")
	local titleKey = props.title or (if entry then entry.title else nil)
	return e(UI.Leaderboard, {
		title = if titleKey then UI.text(titleKey) else fallback,
		rows = if entry then entry.rows else {},
		selfUserId = selfUserId(),
		selfValue = if mine then mine.value else nil,
		selfRank = if mine then mine.rank else nil,
		format = props.format,
		size = props.size,
		layoutOrder = props.layoutOrder,
	})
end

-- The screen: a tab per board, the chosen board below. props: boardId? (first tab), formats?
-- ({ [boardId] = "number" | "time" }), onClose (from the screen host).
function Views.Screen(props: any): any
	local all = ReactCharm.useAtom(function(): any
		return State.all(rawState())
	end)
	local chosen, setChosen = React.useState(props.boardId)
	local title = UI.useText("Leaderboards.title")
	local current = all[1]
	for _, board in all do
		if board.id == chosen then
			current = board
		end
	end
	local tabs: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Wraps = true,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for i, board in all do
		tabs[`Tab{board.id}`] = e(UI.Button, {
			text = UI.text(board.entry.title),
			variant = if current ~= nil and board.id == current.id then "primary" else "secondary",
			layoutOrder = i,
			onActivated = function()
				setChosen(board.id)
			end,
		})
	end
	local formats = props.formats or {}
	return e(UI.Modal, { open = true, title = title, onClose = props.onClose }, {
		Tabs = e("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
		}, tabs),
		Board = e(Views.Board, {
			boardId = if current then current.id else "",
			format = if current then formats[current.id] else nil,
			layoutOrder = 2,
		}),
	})
end

-- The board in a scrolling frame that fills `parent` (a SurfaceGui the game placed in the world).
function Views.Mounted(props: any): any
	return e("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 6,
	}, {
		Board = e(Views.Board, props),
	})
end

return Views
