--!strict
--[[
	Modal: dimmed full-screen backdrop + centred Panel with a title and a close (X) button.
	Render it inside a ScreenGui whose ScreenInsets keep it in the safe area (see AutoScale /
	README); the panel is capped to 92% x 88% of the screen so it never runs under notches.

	props:
		open: boolean                when false nothing is rendered
		title: string?
		onClose: (() -> ())?         close button + backdrop tap (unless dismissOnBackdrop == false)
		dismissOnBackdrop: boolean?
		size: UDim2?                 panel size (default 0.6 x auto, min 320 px wide)
		children
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Panel = require(script.Parent.Panel)
local Primitives = require(script.Parent.Primitives)
local Theme = require(script.Parent.Theme)

local e = React.createElement

export type Props = {
	open: boolean,
	title: string?,
	onClose: (() -> ())?,
	dismissOnBackdrop: boolean?,
	size: UDim2?,
	children: any,
}

local function Modal(props: Props)
	if not props.open then
		return nil
	end
	local function close()
		if props.onClose then
			props.onClose()
		end
	end
	local target = Theme.touchTarget
	return e("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Modal = true, -- frees the mouse in first person while open
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 50,
		[React.Event.Activated] = function()
			if props.dismissOnBackdrop ~= false then
				close()
			end
		end,
	}, {
		Body = e("Frame", {
			BackgroundTransparency = 1,
			Size = props.size or UDim2.fromScale(0.6, 0),
			AutomaticSize = if props.size then Enum.AutomaticSize.None else Enum.AutomaticSize.Y,
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 51,
		}, {
			Limit = e("UISizeConstraint", { MinSize = Vector2.new(320, 0), MaxSize = Vector2.new(640, 560) }),
			-- swallow taps on the panel so they don't hit the backdrop
			Sink = e("TextButton", {
				Text = "",
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				ZIndex = 51,
			}),
			Panel = e(Panel, { title = props.title }, props.children),
			Close = if props.onClose
				then e("TextButton", {
					Text = "X",
					FontFace = Theme.font("display"),
					TextSize = Theme.text.title,
					TextColor3 = Theme.color("text"),
					BackgroundColor3 = Theme.color("danger"),
					Size = UDim2.fromOffset(target, target),
					Position = UDim2.new(1, 8, 0, -8),
					AnchorPoint = Vector2.new(1, 0),
					ZIndex = 60,
					[React.Event.Activated] = close,
				}, {
					Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
					Stroke = Primitives.stroke(),
				})
				else nil,
		}),
	})
end

return Modal
