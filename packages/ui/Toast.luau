--!strict
--[[
	Toast: one notice pill. Slides/fades in on mount (tweened).

	props: text: string, rarity: string? (tints the stroke), count: number? (shows "x3"),
	       layoutOrder: number?, onDismiss: (() -> ())? (tap to dismiss)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Primitives = require(script.Parent.Primitives)
local Theme = require(script.Parent.Theme)
local WrappedText = require(script.Parent.WrappedText)

local e = React.createElement

export type Props = {
	text: string,
	rarity: string?,
	count: number?,
	layoutOrder: number?,
	onDismiss: (() -> ())?,
}

local function Toast(props: Props)
	local measured, setMeasured = React.useState(Theme.touchTarget)
	local strokeColor = if props.rarity then (Theme.rarity(props.rarity)) else Theme.color("accent")
	local text = props.text
	if props.count and props.count > 1 then
		text ..= "  x" .. tostring(props.count)
	end
	return e("TextButton", {
		Text = "",
		AutoButtonColor = false,
		FontFace = Theme.font("bold"),
		TextSize = Theme.text.body,
		TextColor3 = Theme.color("text"),
		BackgroundColor3 = Theme.color("surface"),
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, math.max(Theme.touchTarget, measured)),
		LayoutOrder = props.layoutOrder,
		[React.Event.Activated] = function()
			if props.onDismiss then
				props.onDismiss()
			end
		end,
	}, {
		Corner = Primitives.corner(),
		Stroke = Primitives.stroke(strokeColor, 2),
		Message = e(WrappedText, {
			text = text,
			textSize = "body",
			font = "bold",
			color = "text",
			padding = 10,
			onHeight = setMeasured,
		}),
		Height = e("UISizeConstraint", { MinSize = Vector2.new(0, Theme.touchTarget) }),
	})
end

return Toast
