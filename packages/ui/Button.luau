--!strict
--[[
	Button: themed TextButton with press feedback (UIScale tween) and a >= 44 px touch target.

	props:
		text: string
		variant: "primary" | "secondary" | "danger" | nil (primary)
		disabled: boolean?           greyed out, ignores input
		onActivated: (() -> ())?     fires on Activated (mouse, touch, gamepad A)
		size: UDim2?                 default: auto width, Theme.touchTarget height
	Text fits for any theme font (v1.3.0, TextFit): auto width is at least the text's measured
	width in the real font; with a fixed `size` the text scales down (capped at the theme size).
		position: UDim2?, anchorPoint: Vector2?, layoutOrder: number?
		icon: string?                optional rbxassetid image left of the text
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Primitives = require(script.Parent.Primitives)
local TextFit = require(script.Parent.TextFit)
local Theme = require(script.Parent.Theme)

local e = React.createElement

export type Variant = "primary" | "secondary" | "danger"

export type Props = {
	text: string,
	variant: Variant?,
	disabled: boolean?,
	onActivated: (() -> ())?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	layoutOrder: number?,
	icon: string?,
}

local PRESS_SCALE = 0.94
local PRESS_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RELEASE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local PADDING = 16
local GAP = 6

-- The text's width in the button's real font (yields; nil when it can't be measured).
local function measure(text: string, font: Font, size: number): number?
	local ok, bounds = pcall(function()
		local params = Instance.new("GetTextBoundsParams")
		params.Text = text
		params.Font = font
		params.Size = size
		params.Width = 100000
		return TextService:GetTextBoundsAsync(params)
	end)
	return if ok and typeof(bounds) == "Vector2" then bounds.X else nil
end

local VARIANT_COLOR: { [Variant]: string } = {
	primary = "accent",
	secondary = "accentAlt",
	danger = "danger",
}

local function Button(props: Props)
	local scaleRef = React.useRef(nil :: UIScale?)
	local disabled = props.disabled == true
	local base = if disabled
		then Theme.color("surfaceAlt")
		else Theme.color(VARIANT_COLOR[(props.variant or "primary") :: Variant])
	local target = Theme.touchTarget
	local fixed = props.size ~= nil
	local font = Theme.font("display")
	local textSize = Theme.text.body
	local iconWidth = if props.icon then math.floor(target * 0.6 + 0.5) else 0
	local minWidth, setMinWidth = React.useState(target)
	React.useEffect(function(): any
		if fixed then
			return nil
		end
		local live = true
		task.spawn(function()
			local width = measure(props.text, font, textSize)
			if live and width then
				setMinWidth(
					TextFit.buttonMinWidth(
						width,
						{ padding = PADDING, iconWidth = iconWidth, gap = GAP, minWidth = target }
					)
				)
			end
		end)
		return function()
			live = false
		end
	end, { props.text, font.Family, textSize, iconWidth, target, fixed } :: { any })
	local fit = if fixed then TextFit.fixedLabel(textSize) else TextFit.autoLabel(textSize)

	local function tweenTo(scale: number, info: TweenInfo)
		local s = scaleRef.current
		if s then
			TweenService:Create(s, info, { Scale = scale }):Play()
		end
	end

	return e("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Active = not disabled,
		Selectable = not disabled,
		BackgroundColor3 = base,
		BorderSizePixel = 0,
		Size = props.size or UDim2.fromOffset(0, target),
		AutomaticSize = if props.size then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		LayoutOrder = props.layoutOrder,
		[React.Event.Activated] = function()
			if not disabled and props.onActivated then
				props.onActivated()
			end
		end,
		[React.Event.InputBegan] = (function(_rbx: GuiObject, input: InputObject)
			if disabled then
				return
			end
			local t = input.UserInputType
			if
				t == Enum.UserInputType.MouseButton1
				or t == Enum.UserInputType.Touch
				or input.KeyCode == Enum.KeyCode.ButtonA
			then
				tweenTo(PRESS_SCALE, PRESS_INFO)
			end
		end) :: any,
		[React.Event.InputEnded] = function()
			tweenTo(1, RELEASE_INFO)
		end,
	}, {
		Scale = e("UIScale", { ref = scaleRef }),
		Corner = Primitives.corner(),
		Stroke = Primitives.stroke(Theme.color("outline")),
		Gradient = Primitives.gradient(base),
		Size = e("UISizeConstraint", {
			MinSize = Vector2.new(if fixed then target else math.max(target, minWidth), target),
		}),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, PADDING),
			PaddingRight = UDim.new(0, PADDING),
		}),
		Content = e("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			AutomaticSize = if fixed then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
		}, {
			Layout = Primitives.list(Enum.FillDirection.Horizontal, GAP, Enum.HorizontalAlignment.Center),
			Icon = if props.icon
				then e("ImageLabel", {
					Image = props.icon,
					BackgroundTransparency = 1,
					Size = UDim2.fromScale(0.6, 0.6),
					LayoutOrder = 1,
				}, { Aspect = e("UIAspectRatioConstraint", { AspectRatio = 1 }) })
				else nil,
			Label = e("TextLabel", {
				Text = props.text,
				FontFace = font,
				TextSize = fit.TextSize,
				TextScaled = fit.TextScaled,
				TextColor3 = if disabled then Theme.color("textMuted") else Theme.color("text"),
				TextStrokeTransparency = 0.6,
				BackgroundTransparency = 1,
				AutomaticSize = if fixed then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
				Size = if fixed
					then UDim2.new(1, -(iconWidth + (if iconWidth > 0 then GAP else 0)), 1, 0)
					else UDim2.fromScale(0, 1),
				LayoutOrder = 2,
			}, {
				Fit = if fit.MaxTextSize
					then Primitives.textSize(fit.MinTextSize :: number, fit.MaxTextSize :: number)
					else nil,
			}),
		}),
	})
end

return Button
