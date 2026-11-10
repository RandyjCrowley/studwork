--!strict
--[[
	Core.Client.Hud. OWNED BY AGENT F (core/f-ui). Public API: Types.HudAPI.

	Hud.init(ctx)          called by the client bootstrap with { config, net }; no side effects.
	Hud.mount(opts?)       (re)mounts a React root into a "CoreHud" ScreenGui in PlayerGui:
	                       primary currency (UI.CurrencyCounter, count-up), rate per second
	                       (unless opts.showRate == false), a "next goal" pill (opts.nextGoal()
	                       re-evaluated on every Core.Client.state change), and a toast stack fed by
	                       Feedback.onFeedbackEvent for kind "toast" ("pop"/"item" are rendered by
	                       Core.Client.Feedback, not duplicated here). Bound to Core.Client.state via
	                       react-charm. Mobile first: ScreenInsets = CoreUISafeInsets, UIScale from
	                       the viewport, touch-sized pills. Calling mount twice replaces the HUD.
	Hud.unmount()          unmounts the React root, disconnects listeners, destroys the ScreenGui.
	Module-aware (Hud/Visibility): currency + rate only when Economy is enabled, the goal pill
	whenever the game passes nextGoal, and (v1.2) a mailbox badge "Mailbox (N)" while Mail is
	enabled and state.mailbox has N > 0 items; tapping it calls opts.onMailbox. ctx.isEnabled comes from the client bootstrap.
	No dependency on game code. Requires ReplicatedStorage.UI (packages/ui) in the game project.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages:WaitForChild("React"))
local ReactCharm = require(Packages:WaitForChild("ReactCharm"))
local ReactRoblox = require(Packages:WaitForChild("ReactRoblox"))
local Types = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Types"))
local UI = require(ReplicatedStorage:WaitForChild("UI"))

local Feedback = require(script.Parent.Feedback)
local State = require(script.Parent.State)
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

type AppProps = {
	opts: Types.HudOptions,
	primary: string,
	isEnabled: (name: string) -> boolean,
}

local function HudApp(props: AppProps)
	local state: Types.ReplicatedState = ReactCharm.useAtom(State.atom)
	local opts = props.opts
	local shown = Visibility.of(props.isEnabled, opts)
	local coins = if state.data then (state.data.currency[props.primary] or 0) else 0
	local mailboxCount = if shown.mailbox then Visibility.mailboxCount(state) else 0
	local goal: string? = nil
	if shown.goal and opts.nextGoal then
		local ok, result = pcall(opts.nextGoal)
		goal = if ok and type(result) == "string" and result ~= "" then result else nil
	end

	return e(UI.ScaledRoot, nil, {
		Top = e("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(0, 0),
			AutomaticSize = Enum.AutomaticSize.XY,
			Position = UDim2.new(0.5, 0, 0, 8),
			AnchorPoint = Vector2.new(0.5, 0),
		}, {
			Layout = UI.Primitives.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center),
			Currency = if shown.currency
				then e(UI.CurrencyCounter, {
					value = coins,
					rate = if shown.rate then state.ratePerSec else nil,
					label = props.primary,
					layoutOrder = 1,
				})
				else nil,
			Goal = if goal
				then e("TextLabel", {
					Text = goal,
					FontFace = UI.Theme.font("bold"),
					TextSize = UI.Theme.text.small,
					TextColor3 = UI.Theme.color("outline"),
					BackgroundColor3 = UI.Theme.color("accent"),
					AutomaticSize = Enum.AutomaticSize.XY,
					Size = UDim2.fromOffset(0, 0),
					LayoutOrder = 2,
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
				else nil,
			Mailbox = if mailboxCount > 0
				then e(UI.Button, {
					text = `Mailbox ({mailboxCount})`,
					variant = "secondary",
					layoutOrder = 3,
					onActivated = function()
						if opts.onMailbox then
							task.spawn(opts.onMailbox)
						end
					end,
				})
				else nil,
		}),
		Toasts = e(UI.ToastHost, {
			subscribe = subscribeToasts,
			position = UDim2.new(0.5, 0, 0, 96),
		}),
	})
end

function Hud.init(context: any)
	ctx = context
	if context and context.config and type(context.config.palette) == "table" then
		UI.Theme.setOverrides(context.config.palette)
	end
end

function Hud.mount(opts: Types.HudOptions?)
	Hud.unmount()
	local o: Types.HudOptions = opts or {}
	local primary = if ctx and ctx.config then (ctx.config.balance.primaryCurrency or "Coins") else "Coins"

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
	r:render(e(HudApp, { opts = o, primary = primary, isEnabled = isEnabled }))
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
