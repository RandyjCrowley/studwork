--!strict
--[[
	CurrencyCounter: coin pill showing an abbreviated amount (1.2K / 3.4M / 5.6B ...), an
	optional "+12/s" rate line, with an optional animated count-up when the value changes.

	props:
		value: number
		rate: number?                shows "+<rate>/s" under the amount when given
		icon: string?                image; default is a currency-coloured coin dot
		label: string?               accessible name (e.g. "Coins")
		animate: boolean?            count up/down over `duration` (default true)
		duration: number?            seconds (0.35)
		size: UDim2?, position: UDim2?, anchorPoint: Vector2?, layoutOrder: number?
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Format = require(script.Parent.Format)
local Primitives = require(script.Parent.Primitives)
local Theme = require(script.Parent.Theme)
local UIText = require(script.Parent.Text)

local e = React.createElement

export type Props = {
	value: number,
	rate: number?,
	icon: string?,
	label: string?,
	animate: boolean?,
	duration: number?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	layoutOrder: number?,
}

local DEFAULT_DURATION = 0.35

local function CurrencyCounter(props: Props)
	UIText.useLocale()
	local shown, setShown = React.useBinding(props.value)
	local fromRef = React.useRef(props.value)

	React.useEffect(function(): (() -> ())?
		local target = props.value
		local from = shown:getValue()
		fromRef.current = from
		if props.animate == false or from == target or from ~= from then
			setShown(target)
			return nil
		end
		local duration = props.duration or DEFAULT_DURATION
		local elapsed = 0
		local conn: RBXScriptConnection
		conn = RunService.Heartbeat:Connect(function(dt: number)
			elapsed += dt
			local a = math.min(1, elapsed / duration)
			a = 1 - (1 - a) * (1 - a) -- ease out
			setShown(from + (target - from) * a)
			if a >= 1 then
				conn:Disconnect()
			end
		end)
		return function()
			conn:Disconnect()
		end
	end, { props.value })

	local h = Theme.touchTarget
	return e("Frame", {
		BackgroundColor3 = Theme.color("surface"),
		BorderSizePixel = 0,
		Size = props.size or UDim2.fromOffset(0, h),
		AutomaticSize = if props.size then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		LayoutOrder = props.layoutOrder,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		Stroke = Primitives.stroke(),
		Gradient = Primitives.gradient(Theme.color("surface"), 0.08),
		Shadow = Primitives.shadow(3),
		-- Body holds the layout: a UIListLayout would also lay out the Shadow sibling and an
		-- auto-sized parent with a scale-sized laid-out child grows without bound.
		Body = e("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(0, h),
			AutomaticSize = Enum.AutomaticSize.X,
		}, {
			Padding = e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 14) }),
			Layout = Primitives.list(Enum.FillDirection.Horizontal, 8),
			Icon = e(
				if props.icon then "ImageLabel" else "Frame",
				{
					Image = props.icon,
					BackgroundColor3 = Theme.color("currency"),
					BackgroundTransparency = if props.icon then 1 else 0,
					Size = UDim2.fromOffset(h - 12, h - 12),
					LayoutOrder = 1,
				} :: any,
				{
					Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
					Aspect = e("UIAspectRatioConstraint", { AspectRatio = 1 }),
				}
			),
			Text = e("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(0, 1),
				AutomaticSize = Enum.AutomaticSize.X,
				LayoutOrder = 2,
			}, {
				Layout = Primitives.list(Enum.FillDirection.Vertical, 0),
				Amount = e("TextLabel", {
					Text = shown:map(function(v: number)
						return Format.abbreviate(math.floor(v))
					end),
					FontFace = Theme.font("display"),
					TextSize = if props.rate then Theme.text.title else Theme.text.number,
					TextColor3 = Theme.color("currency"),
					TextStrokeTransparency = 0.5,
					TextXAlignment = Enum.TextXAlignment.Left,
					BackgroundTransparency = 1,
					AutomaticSize = Enum.AutomaticSize.XY,
					LayoutOrder = 1,
				}),
				Rate = if props.rate
					then e("TextLabel", {
						Text = UIText.text("ui.perSecond", { amount = Format.abbreviate(props.rate) }),
						FontFace = Theme.font("bold"),
						TextSize = Theme.text.small,
						TextColor3 = Theme.color("textMuted"),
						TextXAlignment = Enum.TextXAlignment.Left,
						BackgroundTransparency = 1,
						AutomaticSize = Enum.AutomaticSize.XY,
						LayoutOrder = 2,
					})
					else nil,
			}),
		}),
	})
end

return CurrencyCounter
