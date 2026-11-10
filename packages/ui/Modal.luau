--!strict
--[[
	Modal: dimmed full-screen backdrop + centred Panel with a title and a close (X) button.
	Render it inside a ScreenGui whose ScreenInsets keep it in the safe area (see AutoScale /
	README); the panel is capped to 92% x 88% of the screen so it never runs under notches:
	when its content is taller or wider than that, the whole panel (title and close button
	included) is scaled down to fit (Modal.fitScale, v1.2 playtest fix).

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

local fitScale = require(script.Parent.ModalFit).fitScale

export type Props = {
	open: boolean,
	title: string?,
	onClose: (() -> ())?,
	dismissOnBackdrop: boolean?,
	size: UDim2?,
	children: any,
}

local function Modal(props: Props)
	local bodyRef = React.useRef(nil :: Frame?)
	local scale, setScale = React.useState(1)
	React.useEffect(function(): (() -> ())?
		local body = bodyRef.current
		if not props.open or body == nil then
			return nil
		end
		local backdrop = body.Parent :: GuiObject?
		local current = scale
		local function refit()
			if backdrop == nil or body.Parent == nil then
				return
			end
			-- AbsoluteSize includes our own UIScale: divide it out to get the unscaled size
			local s = if current > 0 then current else 1
			local nextScale = fitScale(
				body.AbsoluteSize.X / s,
				body.AbsoluteSize.Y / s,
				backdrop.AbsoluteSize.X,
				backdrop.AbsoluteSize.Y
			)
			if math.abs(nextScale - current) > 0.01 then
				current = nextScale
				setScale(nextScale)
			end
		end
		refit()
		local a = body:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
		local b = if backdrop then backdrop:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit) else nil
		return function()
			a:Disconnect()
			if b then
				b:Disconnect()
			end
		end
	end, { props.open, scale } :: { any })
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
			ref = bodyRef,
		}, {
			Fit = e("UIScale", { Scale = scale }),
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
