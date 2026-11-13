--!strict
--[[
	Goals client: the HUD pill, widget "Goals.goal" (docs/framework/kits/quests.md, Goals "Pill").
	The current goal's text (one line, ellipsized, at most 60% of the screen width) and a chevron
	toward the `widget`'s HUD slot when the goal names one. Active = false and not Selectable: it
	never takes input or gamepad focus. Theme tokens only; text through UI.text; no animation, so
	reduce motion needs nothing here.

	  Pill.WIDGET_ID = "Goals.goal"
	  Pill.ORDER                          its order in topCenter (Economy.currency 1,
	                                      Game.nextGoal 2, Social.mailbox 3)
	  Pill.view(wire) -> GoalView?        extra.goal (wire) -> the view (nil when absent)
	  Pill.chevron(slot) -> string?       the glyph toward a slot, seen from topCenter
	  Pill.maxWidth(viewportX) -> number  the width cap: 60% of the viewport, never below MIN_WIDTH (160)
	  Pill.labelProps(text, theme?) -> props   the TextLabel's properties (specs check them)
	  Pill.component                      the React widget (props.state = raw replicated state)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pill = {}

Pill.WIDGET_ID = "Goals.goal"
Pill.SLOT = "topCenter"
Pill.ORDER = 4
Pill.MAX_WIDTH_SHARE = 0.6
-- A floor for the width cap: the camera's ViewportSize can read 0 (or a few pixels) at join, before the
-- first layout, and a cap of 0 collapsed the pill to "Co…". 160 px holds about 14 characters at the
-- small text size.
Pill.MIN_WIDTH = 160

-- The widest the pill may be on a viewport `viewportX` pixels wide: its share of the width, never below
-- MIN_WIDTH (a viewport that is unknown or tiny counts as the floor, not as 0).
function Pill.maxWidth(viewportX: number?): number
	local x = if type(viewportX) == "number" and viewportX == viewportX then viewportX else 0
	return math.max(Pill.MIN_WIDTH, math.floor(x * Pill.MAX_WIDTH_SHARE))
end

local CHEVRONS: { [string]: string } = {
	left = "←",
	topLeft = "←",
	right = "→",
	topRight = "→",
	bottom = "↓",
}

function Pill.view(wire: any): any
	if type(wire) ~= "table" or type(wire.text) ~= "string" then
		return nil
	end
	return table.freeze({
		id = wire.id,
		index = if type(wire.i) == "number" then wire.i else 0,
		count = if type(wire.n) == "number" then wire.n else 0,
		text = wire.text,
		args = wire.args,
		target = wire.target,
		widget = wire.widget,
		isNext = wire.next == true,
		hidden = wire.hidden == true,
	})
end

function Pill.chevron(slot: string?): string?
	return if slot then CHEVRONS[slot] else nil
end

-- the goal wire in the raw replicated state
function Pill.wireFrom(state: any): any
	local modules = type(state) == "table" and state.modules
	local slice = type(modules) == "table" and modules.Goals
	local extra = type(slice) == "table" and slice.extra
	return if type(extra) == "table" then extra.goal else nil
end

function Pill.labelProps(text: string, theme: any?): { [string]: any }
	local props: { [string]: any } = {
		Text = text,
		Active = false,
		Selectable = false,
		TextTruncate = if theme then theme.truncate else nil,
		TextWrapped = false,
		RichText = false,
		BackgroundTransparency = 0,
	}
	if theme ~= nil then
		props.FontFace = theme.font
		props.TextSize = theme.textSize
		props.TextColor3 = theme.textColor
		props.BackgroundColor3 = theme.background
	end
	return props
end

-- The camera's viewport width, kept current: the width cap follows the camera when it resizes (a
-- rotation, a window drag) and when it only gets its real size after the first layout.
local function useViewportWidth(React: any): number
	local function read(): number
		local camera = workspace.CurrentCamera
		return if camera then camera.ViewportSize.X else 0
	end
	local width, setWidth = React.useState(read())
	React.useEffect(function()
		local conns: { any } = {}
		local function hook()
			local camera = workspace.CurrentCamera
			if camera ~= nil then
				table.insert(
					conns,
					camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
						setWidth(read())
					end)
				)
			end
			setWidth(read())
		end
		hook()
		table.insert(conns, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hook))
		return function()
			for _, conn in conns do
				conn:Disconnect()
			end
		end
	end, {})
	return width
end

local function slotOf(UI: any, widgetId: string?): string?
	if widgetId == nil then
		return nil
	end
	local ok, specs = pcall(UI.widgets)
	local spec = if ok and type(specs) == "table" then specs[widgetId] else nil
	return if type(spec) == "table" then spec.slot else nil
end

-- The drawn pill (a component of its own: the viewport hook runs only while a goal is shown).
local function PillBody(props: any)
	local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React")) :: any
	local view = props.view
	local viewportX = useViewportWidth(React)
	local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
	local e = React.createElement
	local text = UI.text(view.text, view.args)
	local glyph = Pill.chevron(slotOf(UI, view.widget))
	if glyph ~= nil then
		text = text .. "  " .. glyph
	end
	local label = Pill.labelProps(text, {
		font = UI.Theme.font("bold"),
		textSize = UI.Theme.text.small,
		textColor = UI.Theme.color("outline"),
		background = UI.Theme.color("accent"),
		truncate = Enum.TextTruncate.AtEnd,
	})
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Size = UDim2.fromOffset(0, 0)
	label.LayoutOrder = props.layoutOrder
	return e("TextLabel", label, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		Stroke = UI.Primitives.stroke(),
		Padding = e("UIPadding", {
			PaddingTop = UDim.new(0, 4),
			PaddingBottom = UDim.new(0, 4),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
		}),
		Limit = e("UISizeConstraint", {
			MinSize = Vector2.new(Pill.MIN_WIDTH, 0),
			MaxSize = Vector2.new(Pill.maxWidth(viewportX), math.huge),
		}),
	})
end

local function PillWidget(props: any)
	local view = Pill.view(Pill.wireFrom(props.state))
	if view == nil or view.hidden then
		return nil -- nothing is required or drawn without a visible goal
	end
	local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React")) :: any
	return React.createElement(PillBody, { view = view, layoutOrder = props.layoutOrder })
end

Pill.component = PillWidget
Pill.widget = table.freeze({ slot = Pill.SLOT, order = Pill.ORDER, module = "Goals", component = PillWidget })

return Pill
