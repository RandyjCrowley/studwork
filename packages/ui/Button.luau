--!strict
--[[
	Button: themed TextButton with press feedback (UIScale tween) and a >= 44 px touch target.

	props:
		text: string
		variant: "primary" | "secondary" | "danger" | nil (primary)
		disabled: boolean?           greyed out, ignores input
		onActivated: (() -> ())?     fires on Activated (mouse, touch, gamepad A)
		size: UDim2?                 default: auto width, Theme.touchTarget height
		position: UDim2?, anchorPoint: Vector2?, layoutOrder: number?
		icon: string?                optional rbxassetid image left of the text
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Primitives = require(script.Parent.Primitives)
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
		Size = e("UISizeConstraint", { MinSize = Vector2.new(target, target) }),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, 16),
			PaddingRight = UDim.new(0, 16),
		}),
		Content = e("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			AutomaticSize = Enum.AutomaticSize.X,
		}, {
			Layout = Primitives.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center),
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
				FontFace = Theme.font("display"),
				TextSize = Theme.text.body,
				TextColor3 = if disabled then Theme.color("textMuted") else Theme.color("text"),
				TextStrokeTransparency = 0.6,
				BackgroundTransparency = 1,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromScale(0, 1),
				LayoutOrder = 2,
			}),
		}),
	})
end

return Button
