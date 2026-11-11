--!strict
--[[
	Core.Client.Hud / StudWork.Client.Hud (module-api.md §13). Public API: Types.HudAPI.

	Hud.init(ctx)      called by the client bootstrap with { config, net, isEnabled }: installs the
	                   runtime's merged theme (ClientTheme) into UI.Theme (+ legacy
	                   GameConfig.palette overrides). No instances created.
	Hud.mount(opts?)   (re)mounts the HUD into a "CoreHud" ScreenGui (DisplayOrder 5, CoreUISafeInsets)
	                   per GameConfig.client.hud:
	                     nil | "default"        the default slot layout (below)
	                     false                  no HUD (mount is a no-op; toasts/screens still work)
	                     <ModuleScript | component>  a custom layout component, rendered with
	                                            props { slots = { [slot] = {elements} }, toasts,
	                                            state, opts }
	                     { layout = <one of the above>, widgets = { [id] = false | spec } }
	                   opts (v1.2, unchanged): nextGoal, showRate, onMailbox.
	Hud.unmount()      unmounts the React root and destroys the ScreenGui.
	Hud.addWidget(id, spec | false)   = UI.registerWidget (modules / games contribute widgets).

	Slots: topLeft, topCenter, topRight, left, right, bottom (UI.HudLayout). Default widgets:
	  "Economy.currency" topCenter 1 (Economy enabled): primary currency + rate (opts.showRate)
	  "Game.nextGoal"    topCenter 2 (opts.nextGoal given): the next-goal pill
	  "Social.mailbox"   topCenter 3 (Mail enabled, N > 0 messages): "Mailbox (N)"; tapping calls
	                     opts.onMailbox, or opens the "Mailbox" screen (UI.open) when none is given
	Toasts (Feedback "toast" events) render under the top-centre slot in every layout.
	State: the per-module client slices of the raw replicated state (Hud/Slices), not the compat
	FlatState. The default layout is pixel-identical to the v1.2 HUD.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages:WaitForChild("React"))
local ReactCharm = require(Packages:WaitForChild("ReactCharm"))
local ReactRoblox = require(Packages:WaitForChild("ReactRoblox"))
local Types = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Types"))
local UI = require(ReplicatedStorage:WaitForChild("UI"))

local Actions = require(script.Parent.Actions)
local ClientTheme = require(script.Parent.Theme)
local Feedback = require(script.Parent.Feedback)
local State = require(script.Parent.State)
local Slices = require(script.Slices)
local Visibility = require(script.Visibility)

local e = React.createElement

local Hud = {}

local ctx: any = nil
local gui: ScreenGui? = nil
local root: any = nil

local TOAST_KINDS: { [string]: boolean } = { toast = true }

local function subscribeToasts(push: (text: string, rarity: string?) -> ()): () -> ()
	local conn = Feedback.onFeedbackEvent(function(kind: string, text: string, rarity: Types.RarityTier?)
		if type(text) ~= "string" or text == "" then
			return
		end
		if TOAST_KINDS[kind] then
			push(text, rarity)
		end
	end)
	return function()
		conn:Disconnect()
	end
end

-- Default widgets ---------------------------------------------------------------------------------

type WidgetProps = { state: any, opts: Types.HudOptions, primary: string, layoutOrder: number }

local function CurrencyWidget(props: WidgetProps)
	return e(UI.CurrencyCounter, {
		value = Slices.currency(props.state, props.primary),
		rate = if props.opts.showRate ~= false then (Slices.ratePerSec(props.state) or 0) else nil,
		label = props.primary,
		layoutOrder = props.layoutOrder,
	})
end

local function NextGoalWidget(props: WidgetProps)
	local nextGoal = props.opts.nextGoal
	if nextGoal == nil then
		return nil
	end
	local ok, result = pcall(nextGoal)
	local goal = if ok and type(result) == "string" and result ~= "" then result else nil
	if goal == nil then
		return nil
	end
	return e("TextLabel", {
		Text = goal,
		FontFace = UI.Theme.font("bold"),
		TextSize = UI.Theme.text.small,
		TextColor3 = UI.Theme.color("outline"),
		BackgroundColor3 = UI.Theme.color("accent"),
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		LayoutOrder = props.layoutOrder,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		Stroke = UI.Primitives.stroke(),
		Padding = e("UIPadding", {
			PaddingTop = UDim.new(0, 4),
			PaddingBottom = UDim.new(0, 4),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
		}),
		Limit = e("UISizeConstraint", { MaxSize = Vector2.new(360, math.huge) }),
	})
end

local function openMailbox()
	UI.open("Mailbox", {
		bind = function(): any
			return { messages = Slices.mailbox(State.raw()) }
		end,
		onClaim = function(id: any)
			Actions.claimMail(id)
		end,
	})
end

local function MailboxWidget(props: WidgetProps)
	local count = Visibility.mailboxCount(props.state)
	if count <= 0 then
		return nil
	end
	return e(UI.Button, {
		text = `Mailbox ({count})`,
		variant = "secondary",
		layoutOrder = props.layoutOrder,
		onActivated = function()
			if props.opts.onMailbox then
				task.spawn(props.opts.onMailbox)
			else
				openMailbox()
			end
		end,
	})
end

Hud.DEFAULT_WIDGETS = table.freeze({
	["Economy.currency"] = table.freeze({
		slot = "topCenter",
		order = 1,
		module = "Economy",
		component = CurrencyWidget,
	}),
	["Game.nextGoal"] = table.freeze({ slot = "topCenter", order = 2, component = NextGoalWidget }),
	["Social.mailbox"] = table.freeze({
		slot = "topCenter",
		order = 3,
		module = "Mail",
		component = MailboxWidget,
	}),
})

-- Default layout ----------------------------------------------------------------------------------

type SlotPlace = {
	position: UDim2,
	anchor: Vector2,
	direction: Enum.FillDirection,
	align: Enum.HorizontalAlignment,
}

local SLOT_PLACES: { [string]: SlotPlace } = {
	topCenter = {
		position = UDim2.new(0.5, 0, 0, 8),
		anchor = Vector2.new(0.5, 0),
		direction = Enum.FillDirection.Vertical,
		align = Enum.HorizontalAlignment.Center,
	},
	topLeft = {
		position = UDim2.new(0, 12, 0, 8),
		anchor = Vector2.new(0, 0),
		direction = Enum.FillDirection.Vertical,
		align = Enum.HorizontalAlignment.Left,
	},
	topRight = {
		position = UDim2.new(1, -12, 0, 8),
		anchor = Vector2.new(1, 0),
		direction = Enum.FillDirection.Vertical,
		align = Enum.HorizontalAlignment.Right,
	},
	left = {
		position = UDim2.new(0, 12, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		direction = Enum.FillDirection.Vertical,
		align = Enum.HorizontalAlignment.Left,
	},
	right = {
		position = UDim2.new(1, -12, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		direction = Enum.FillDirection.Vertical,
		align = Enum.HorizontalAlignment.Right,
	},
	bottom = {
		position = UDim2.new(0.5, 0, 1, -8),
		anchor = Vector2.new(0.5, 1),
		direction = Enum.FillDirection.Horizontal,
		align = Enum.HorizontalAlignment.Center,
	},
}

local SLOT_NAMES: { [string]: string } = {
	topCenter = "Top",
	topLeft = "TopLeft",
	topRight = "TopRight",
	left = "Left",
	right = "Right",
	bottom = "Bottom",
}

local function DefaultLayout(props: { slots: { [string]: { [string]: any } }, toasts: any })
	local children: { [string]: any } = {}
	for _, slot in UI.HudLayout.SLOTS do
		local elements = props.slots[slot]
		if next(elements) ~= nil then
			local place = SLOT_PLACES[slot]
			local inner: { [string]: any } = {
				Layout = UI.Primitives.list(place.direction, 6, place.align),
			}
			for k, v in elements do
				inner[k] = v
			end
			children[SLOT_NAMES[slot]] = e("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(0, 0),
				AutomaticSize = Enum.AutomaticSize.XY,
				Position = place.position,
				AnchorPoint = place.anchor,
			}, inner)
		end
	end
	children.Toasts = props.toasts
	return e(UI.ScaledRoot, nil, children)
end

-- App ---------------------------------------------------------------------------------------------

type AppProps = {
	opts: Types.HudOptions,
	primary: string,
	isEnabled: (name: string) -> boolean,
	layout: any,
	overrides: { [string]: any },
}

local function HudApp(props: AppProps)
	local state = ReactCharm.useAtom(State.raw)
	local version, setVersion = React.useState(0)
	React.useEffect(function()
		local function bump()
			setVersion(function(v: number): number
				return v + 1
			end)
		end
		local offWidgets = UI.onWidgetsChanged(bump)
		local offTheme = UI.Theme.subscribe(bump)
		return function()
			offWidgets()
			offTheme()
		end
	end, {})
	local _ = version

	local registered, removals = UI.widgets()
	local overrides = table.clone(removals)
	for id, spec in props.overrides do
		overrides[id] = spec
	end
	local placed = UI.HudLayout.resolve(Hud.DEFAULT_WIDGETS, registered, overrides, props.isEnabled)
	local slots: { [string]: { [string]: any } } = {}
	for slot, list in placed do
		local elements: { [string]: any } = {}
		for i, w in list do
			elements[w.id] = e(w.spec.component, {
				state = state,
				opts = props.opts,
				primary = props.primary,
				layoutOrder = i,
			})
		end
		slots[slot] = elements
	end
	local toasts = e(UI.ToastHost, {
		subscribe = subscribeToasts,
		position = UDim2.new(0.5, 0, 0, 96),
	})
	local layout = props.layout or DefaultLayout
	return e(layout, { slots = slots, toasts = toasts, state = state, opts = props.opts })
end

function Hud.init(context: any)
	ctx = context
	local palette = if context
			and context.config
			and type(context.config.palette) == "table"
		then context.config.palette
		else nil
	UI.Theme.set(ClientTheme.current(), palette)
end

function Hud.addWidget(id: string, spec: any)
	UI.registerWidget(id, spec)
end

-- The HUD config: GameConfig.client.hud (a v1.3 runtime) or the v1.2 view's client.hud.
local function hudConfig(): any
	local value = ClientTheme.clientHud()
	if value == nil and ctx and type(ctx.config) == "table" and type(ctx.config.client) == "table" then
		value = ctx.config.client.hud
	end
	return UI.HudLayout.config(value, function(m: any): any
		return (require :: any)(m)
	end)
end

function Hud.mount(opts: Types.HudOptions?)
	Hud.unmount()
	local o: Types.HudOptions = opts or {}
	local cfg = hudConfig()
	if cfg.mode == "off" then
		return
	end
	local primary = if ctx
			and ctx.config
			and ctx.config.balance
		then (ctx.config.balance.primaryCurrency or "Coins")
		else "Coins"

	local screen = Instance.new("ScreenGui")
	screen.Name = "CoreHud"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets -- below the top bar, clear of notches
	screen.SafeAreaCompatibility = Enum.SafeAreaCompatibility.FullscreenExtension
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.DisplayOrder = 5
	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = screen

	local r = ReactRoblox.createRoot(screen)
	local isEnabled = if ctx and ctx.isEnabled
		then ctx.isEnabled
		else function(_name: string): boolean
			return true
		end
	r:render(e(HudApp, {
		opts = o,
		primary = primary,
		isEnabled = isEnabled,
		layout = if cfg.mode == "custom" then cfg.layout else nil,
		overrides = cfg.widgets,
	}))
	root = r
end

function Hud.unmount()
	if root then
		root:unmount()
		root = nil
	end
	if gui then
		gui:Destroy()
		gui = nil
	end
end

return Hud
