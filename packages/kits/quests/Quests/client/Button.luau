--!strict
--[[
	The HUD button (widget "Quests.button", slot right, order 4): opens the board; a dot shows while
	something is claimable. A UI.Button (Selectable, touch target from the theme). Loaded lazily by
	client/init.luau.

	props (the HUD host): state, layoutOrder; env (client/init.luau): cfg, open.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React")) :: any
local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
local State = require(script.Parent.State)

local e = React.createElement
local Theme = UI.Theme

local DOT = 14

local function HudButton(props: any): any
	local env = props.env or {}
	local views = State.views(props.state, env.cfg or {})
	local claimable = State.claimable(views)
	local children: { [string]: any } = {
		Button = e(UI.Button, {
			text = UI.text("Quests.button"),
			variant = "secondary",
			onActivated = function()
				env.open(nil)
			end,
		}),
	}
	if claimable > 0 then
		children.Dot = e("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 2, 0, -2),
			Size = UDim2.fromOffset(DOT, DOT),
			BackgroundColor3 = Theme.color("success"),
			BorderSizePixel = 0,
			Active = false,
			ZIndex = 5,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			Stroke = e("UIStroke", { Color = Theme.color("surface"), Thickness = 2 }),
		})
	end
	return e("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(),
		AutomaticSize = Enum.AutomaticSize.XY,
		LayoutOrder = props.layoutOrder,
	}, children)
end

return HudButton
