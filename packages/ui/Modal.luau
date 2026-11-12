--!strict
--[[
	Modal: dimmed full-screen backdrop + centred Panel with a title and a close (X) button.
	Render it inside a ScreenGui whose ScreenInsets keep it in the safe area (see AutoScale /
	README) and whose ZIndexBehavior is Sibling (under Global the backdrop covers the panel; the
	Modal warns once). The panel is capped to 92% x 88% of the screen so it never runs under
	notches: the content area scrolls when it is taller (v1.6.2), and the whole panel is scaled
	down (Modal.fitScale, v1.2 playtest fix) only as far as ModalFit.minScale allows.

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

local ModalFit = require(script.Parent.ModalFit)
local ModalLayers = require(script.Parent.ModalLayers)

export type Props = {
	open: boolean,
	title: string?,
	onClose: (() -> ())?,
	dismissOnBackdrop: boolean?,
	size: UDim2?,
	children: any,
}

-- ScreenGuis already warned about ZIndexBehavior.Global (once each).
local warnedGlobal: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Product of the UIScales that apply to `inst` from above (a UIScale scales its parent and
-- everything under it), e.g. UI.ScaledRoot's responsive scale.
local function scaleAbove(inst: Instance): number
	local s = 1
	local node: Instance? = inst.Parent
	while node and not node:IsA("LayerCollector") do
		local u = node:FindFirstChildOfClass("UIScale")
		if u then
			s *= u.Scale
		end
		node = node.Parent
	end
	return s
end

local function Modal(props: Props)
	local bodyRef = React.useRef(nil :: Frame?)
	local listRef = React.useRef(nil :: UIListLayout?)
	local scale, setScale = React.useState(1)
	-- v1.6.2: the scroll area's height is SET from the measured content and the screen
	-- (ModalFit.contentHeight), never left to AutomaticSize + UISizeConstraint, which let the panel
	-- grow past the screen in Studio with the content laid out above it.
	local scrollHeight, setScrollHeight = React.useState(Theme.touchTarget * 4)
	local scrolls, setScrolls = React.useState(false)
	React.useEffect(function(): (() -> ())?
		local body = bodyRef.current
		local list = listRef.current
		if not props.open or body == nil then
			return nil
		end
		local backdrop = body.Parent :: GuiObject?
		-- v1.6.2: under ZIndexBehavior.Global the backdrop (ZIndex 50) draws over the panel's
		-- contents; the kit's own ScreenGuis are Sibling, a game's must be too.
		local layer = body:FindFirstAncestorWhichIsA("ScreenGui")
		if layer and layer.ZIndexBehavior == Enum.ZIndexBehavior.Global and not warnedGlobal[layer] then
			warnedGlobal[layer] = true
			warn(
				`[StudWork UI] UI.Modal in ScreenGui '{layer.Name}' needs ZIndexBehavior = Sibling;`
					.. " under Global the backdrop covers the panel"
			)
		end
		local current = scale
		local function refit()
			if backdrop == nil or body.Parent == nil then
				return
			end
			-- AbsoluteSize includes our own UIScale: divide it out to get the unscaled size
			local s = if current > 0 then current else 1
			local nextScale = math.max(
				ModalFit.minScale(Theme.tokens),
				ModalFit.fitScale(
					body.AbsoluteSize.X / s,
					body.AbsoluteSize.Y / s,
					backdrop.AbsoluteSize.X,
					backdrop.AbsoluteSize.Y
				)
			)
			local outer = scaleAbove(backdrop)
			if list ~= nil then
				local pad = Theme.metrics.padding
				local chrome = 2 * pad + (if props.title then Theme.text.title + 6 + 8 else 0) + 4
				local content = list.AbsoluteContentSize.Y / math.max(outer * s, 0.01)
				local h = ModalFit.contentHeight(
					backdrop.AbsoluteSize.Y,
					outer,
					nextScale,
					chrome,
					content,
					Theme.touchTarget
				)
				setScrollHeight(math.ceil(h))
				setScrolls(content > h + 1)
			end
			if math.abs(nextScale - current) > 0.01 then
				current = nextScale
				setScale(nextScale)
			end
		end
		refit()
		local a = body:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
		local b = if backdrop then backdrop:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit) else nil
		local c = if list then list:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(refit) else nil
		return function()
			a:Disconnect()
			if b then
				b:Disconnect()
			end
			if c then
				c:Disconnect()
			end
		end
	end, { props.open, scale, props.title } :: { any })
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
		BackgroundColor3 = Theme.color("backdrop"),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = ModalLayers.backdrop,
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
			ZIndex = ModalLayers.body,
			ref = bodyRef,
		}, {
			Fit = e("UIScale", { Scale = scale }),
			Limit = e("UISizeConstraint", { MinSize = Vector2.new(320, 0), MaxSize = Vector2.new(640, 560) }),
			-- swallow taps on the panel so they don't hit the backdrop
			Sink = e("TextButton", {
				Text = "",
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				ZIndex = ModalLayers.sink,
			}),
			Panel = e(Panel, { title = props.title, zIndex = ModalLayers.panel }, {
				Content = e("ScrollingFrame", {
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					Size = UDim2.new(1, 0, 0, scrollHeight),
					AutomaticCanvasSize = Enum.AutomaticSize.Y,
					CanvasSize = UDim2.new(),
					ScrollingDirection = Enum.ScrollingDirection.Y,
					ScrollBarThickness = if scrolls then 6 else 0, -- a bar only when it scrolls
					-- The panel is capped; content scrolls instead of shrinking its text.
				}, {
					Layout = e("UIListLayout", {
						FillDirection = Enum.FillDirection.Vertical,
						Padding = UDim.new(0, Theme.metrics.padding),
						HorizontalAlignment = Enum.HorizontalAlignment.Left,
						SortOrder = Enum.SortOrder.LayoutOrder,
						ref = listRef,
					}),
					Children = e(React.Fragment, nil, props.children),
				}),
			}),
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
					ZIndex = ModalLayers.close,
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
