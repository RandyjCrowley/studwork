--!strict
--[[
	The HUD tracker (widget "Quests.tracker", slot right, order 5): up to `pinMax` pinned quests,
	one line each with a bar. A complete one shows the Claim hint in place of the count. Tapping a
	line opens the board on that quest's tab. Not Selectable: it never takes gamepad focus from the
	game. Nothing pinned = nothing drawn. Loaded lazily by client/init.luau.

	props (the HUD host): state, layoutOrder; env (client/init.luau): cfg, open.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React")) :: any
local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
local Row = require(script.Parent.Row)
local State = require(script.Parent.State)

local e = React.createElement
local Theme = UI.Theme

local WIDTH = 200

local function Line(props: any): any
	local view = props.view
	local value, target, ratio = State.progressOf(view)
	local done = view.status == "complete"
	local right = if done
		then UI.text("Quests.claim")
		else UI.text("Quests.progress", { value = value, target = target })
	return e("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		BackgroundColor3 = Theme.color("surface"),
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Theme.touchTarget),
		LayoutOrder = props.layoutOrder,
		[React.Event.Activated] = function()
			props.onOpen(State.tabOf(view))
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = Theme.cornerRadius() }),
		Pad = e("UIPadding", {
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 8),
			PaddingTop = UDim.new(0, 4),
			PaddingBottom = UDim.new(0, 4),
		}),
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 3),
			VerticalAlignment = Enum.VerticalAlignment.Center,
		}),
		Head = e("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
		}, {
			Layout = e(
				"UIListLayout",
				{ FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder }
			),
			Title = Row.label({
				text = UI.text(view.title),
				size = UDim2.new(0.65, 0, 0, 0),
				layoutOrder = 1,
			}),
			Value = Row.label({
				text = right,
				font = "bold",
				color = if done then "success" else "text",
				align = Enum.TextXAlignment.Right,
				size = UDim2.new(0.35, 0, 0, 0),
				layoutOrder = 2,
			}),
		}),
		Bar = e(
			Row.Bar,
			{ ratio = ratio, color = if done then "success" else "accent", height = 6, layoutOrder = 2 }
		),
	})
end

local function Tracker(props: any): any
	UI.useText("Quests.title") -- re-render on a locale change
	local env = props.env or {}
	local cfg = env.cfg or {}
	local views = State.views(props.state, cfg)
	local pinned = State.pinned(views, cfg.pinMax)
	if #pinned == 0 then
		return nil
	end
	local lines: { [string]: any } = {
		Layout = e("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	}
	for i, view in ipairs(pinned) do
		lines[`Line_{view.id}`] = e(Line, {
			view = view,
			layoutOrder = i,
			onOpen = function(tab: string)
				env.open(tab)
			end,
		})
	end
	return e("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = props.layoutOrder,
	}, lines)
end

return Tracker
