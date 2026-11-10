--!strict
--[[
	Toast: one notice pill. Slides/fades in on mount (tweened).

	props: text: string, rarity: string? (tints the stroke), count: number? (shows "x3"),
	       layoutOrder: number?, onDismiss: (() -> ())? (tap to dismiss)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Primitives = require(script.Parent.Primitives)
local Theme = require(script.Parent.Theme)

local e = React.createElement

export type Props = {
	text: string,
	rarity: string?,
	count: number?,
	layoutOrder: number?,
	onDismiss: (() -> ())?,
}

local IN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local function Toast(props: Props)
	local scaleRef = React.useRef(nil :: UIScale?)
	React.useEffect(function()
		local s = scaleRef.current
		if s then
			s.Scale = 0.6
			TweenService:Create(s, IN_INFO, { Scale = 1 }):Play()
		end
	end, {})
	local strokeColor = if props.rarity then (Theme.rarity(props.rarity)) else Theme.color("accent")
	local text = props.text
	if props.count and props.count > 1 then
		text ..= "  x" .. tostring(props.count)
	end
	return e("TextButton", {
		Text = text,
		AutoButtonColor = false,
		FontFace = Theme.font("bold"),
		TextSize = Theme.text.body,
		TextWrapped = true,
		TextColor3 = Theme.color("text"),
		BackgroundColor3 = Theme.color("surface"),
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = props.layoutOrder,
		[React.Event.Activated] = function()
			if props.onDismiss then
				props.onDismiss()
			end
		end,
	}, {
		Scale = e("UIScale", { ref = scaleRef }),
		Corner = Primitives.corner(),
		Stroke = Primitives.stroke(strokeColor, 2),
		Padding = Primitives.padding(10),
		Height = e("UISizeConstraint", { MinSize = Vector2.new(0, Theme.touchTarget) }),
	})
end

return Toast
