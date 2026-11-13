--!strict
--[[
	The quest board (React): screen "Quests", a UI.Modal with a tab per kind (Daily, Weekly, Story,
	and Event / Rewards waiting while there are some), the rows of the chosen tab, "Resets in h:mm"
	for daily and weekly, Claim, Reroll, Track and an Odds button on every roll reward.

	Loaded lazily by client/init.luau. Opened only by the player (the HUD button) or the game
	(`Quests.open`); never opens itself, and it takes no input outside its own modal.

	props (UI.open): tab? (first tab shown), gamepad? (opened from a gamepad: select the first Claim,
	else the first tab), onClose (from the screen host), env (client/init.luau: cfg, items,
	primaryCurrency, claim, reroll, pin, openOdds, now).
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages:WaitForChild("React")) :: any
local ReactCharm = require(Packages:WaitForChild("ReactCharm")) :: any
local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
local Row = require(script.Parent.Row)
local State = require(script.Parent.State)

local e = React.createElement

local Board = {}

local MUTED = "textMuted" -- a theme colour key

local TAB_KEYS: { [string]: string } = {
	daily = "Quests.tab.daily",
	weekly = "Quests.tab.weekly",
	chain = "Quests.tab.chain",
	event = "Quests.tab.event",
	waiting = "Quests.tab.waiting",
}

local function rawState(): any
	local StudWork = require(ReplicatedStorage:WaitForChild("Framework")) :: any
	return StudWork.Client.state()
end

-- Selects the first Claim button, else the first tab, inside `root` (a gamepad-opened board only).
local function selectFirst(root: Instance, firstTab: string?)
	local bestName: string? = nil
	local best: Instance? = nil
	for _, d in root:GetDescendants() do
		if
			d:IsA("Frame")
			and string.match(d.Name, "^Claim%d+$")
			and (bestName == nil or d.Name < bestName)
		then
			bestName = d.Name
			best = d
		end
	end
	if best == nil and firstTab ~= nil then
		best = root:FindFirstChild("Tab_" .. firstTab, true)
	end
	if best ~= nil then
		local button = best:FindFirstChildWhichIsA("GuiButton", true)
		if button ~= nil then
			GuiService.SelectedObject = button
		end
	end
end
Board.selectFirst = selectFirst

function Board.Screen(props: any): any
	local env = props.env or {}
	local cfg = env.cfg or {}
	UI.useText("Quests.title") -- re-render on a locale change
	local state = ReactCharm.useAtom(rawState)
	local views = State.views(state, cfg)
	local tabs = State.tabsOf(views)
	local chosen, setChosen = React.useState(props.tab or "daily")
	local now, setNow = React.useState(env.now())
	local rootRef = React.useRef(nil :: Frame?)

	local tab = chosen
	if table.find(tabs, tab) == nil then
		tab = tabs[1]
	end

	-- "Resets in": a coarse clock while the board is open
	React.useEffect(function(): any
		local alive = true
		task.spawn(function()
			while alive do
				task.wait(1)
				if alive then
					setNow(env.now())
				end
			end
		end)
		return function()
			alive = false
		end
	end, {})

	-- gamepad: selection only when the player opened the board from a gamepad; B closes
	React.useEffect(function(): any
		if props.gamepad == true then
			task.defer(function()
				local root = rootRef.current
				if root ~= nil and root.Parent ~= nil then
					selectFirst(root, tabs[1])
				end
			end)
		end
		local connection = UserInputService.InputBegan:Connect(function(input: InputObject)
			if input.KeyCode == Enum.KeyCode.ButtonB and props.onClose then
				props.onClose()
			end
		end)
		return function()
			connection:Disconnect()
		end
	end, {})

	local pinCount = 0
	for _, v in views do
		if v.pinned then
			pinCount += 1
		end
	end
	local pinMax = if type(cfg.pinMax) == "number" then cfg.pinMax else 3
	local odds = State.odds(state)

	local tabButtons: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Wraps = true,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for i, id in ipairs(tabs) do
		tabButtons["Tab_" .. id] = e("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(),
			AutomaticSize = Enum.AutomaticSize.XY,
			LayoutOrder = i,
		}, {
			Button = e(UI.Button, {
				text = UI.text(TAB_KEYS[id]),
				variant = if id == tab then "primary" else "secondary",
				onActivated = function()
					setChosen(id)
				end,
			}),
		})
	end

	local children: { [string]: any } = {
		Tabs = e("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
		}, tabButtons),
	}

	local shown = State.inTab(views, tab)
	local endsAt = State.tabEndsAt(views, tab)
	if endsAt ~= nil then
		children.Resets = Row.label({
			text = UI.text(State.resetsLine(State.resetsIn(endsAt, now))),
			color = MUTED,
			layoutOrder = 2,
		})
	end

	local rows: { [string]: any } = {
		Layout = e("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	}
	if #shown == 0 then
		rows.Empty = Row.label({ text = UI.text("Quests.empty"), color = MUTED, layoutOrder = 1 })
	end
	for i, view in ipairs(shown) do
		local key = if view.waiting then `{view.id}_w{tostring(view.periodId)}` else view.id
		rows[key] = e(Row.Component, {
			view = view,
			index = i,
			env = env,
			odds = odds,
			pinCount = pinCount,
			pinMax = pinMax,
			onClaim = function(v: any)
				env.claim(v.id)
			end,
			onReroll = function(v: any)
				env.reroll(v.kind, v.slot)
			end,
			onPin = function(v: any)
				env.pin(v.id, not v.pinned)
			end,
			onOdds = function(tableId: string)
				env.openOdds(tableId, odds)
			end,
		})
	end
	children.Rows = e("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 3,
	}, rows)

	-- a full-size, transparent, inactive wrapper: it only gives the gamepad selection a root
	return e("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ref = rootRef,
		Name = "QuestsBoardRoot",
	}, {
		Modal = e(UI.Modal, {
			open = true,
			title = UI.text("Quests.title"),
			onClose = props.onClose,
			-- no `size`: UI.Modal then sizes the panel to its content (0.6 of the screen wide, min 320 px)
			-- and scrolls it inside the screen; a given size turns AutomaticSize off and a 0 height
			-- hung the panel off-screen
		}, children),
	})
end

return Board
