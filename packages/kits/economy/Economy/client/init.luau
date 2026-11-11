--!strict
--[[
	Economy client part (module-api.md §9, §13; v1.3.1 R19: one folder per module, found by
	the client runtime as ReplicatedStorage.Modules.Economy.client).

	The HUD currency widget "Economy.currency" (topCenter, order 1: the primary currency
	config.Economy.primaryCurrency, default "Coins", + its rate unless HudOptions.showRate == false).
	It moved here from the framework HUD in v1.3.1 under the same id, registered with
	UI.registerWidget at start (the HUD re-renders on late registration), so
	GameConfig.client.hud.widgets["Economy.currency"] = false / a replacement spec / a bare
	component and a whole-HUD layout keep working. A removal registered before start
	(UI.registerWidget(id, false)) is kept.
	  StudWork.use(Economy).read.<reader>(StudWork.Client.state())   pure readers (client/State.luau)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(script.State)

local WIDGET_ID = "Economy.currency"

local primary = "Coins"

local function CurrencyWidget(props: any)
	local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React")) :: any
	local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
	local opts = props.opts or {}
	return React.createElement(UI.CurrencyCounter, {
		value = State.currency(props.state, primary),
		rate = if opts.showRate ~= false then (State.ratePerSec(props.state) or 0) else nil,
		label = primary,
		layoutOrder = props.layoutOrder,
	})
end

local Economy = {}

Economy.WIDGET_ID = WIDGET_ID
Economy.widget =
	table.freeze({ slot = "topCenter", order = 1, module = "Economy", component = CurrencyWidget })
Economy.api = { read = State }

function Economy.init(ctx: any)
	local config = ctx.config
	if type(config) == "table" and type(config.primaryCurrency) == "string" then
		primary = config.primaryCurrency
	end
end

function Economy.start(_ctx: any)
	local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
	local _, removals = UI.widgets()
	if removals[WIDGET_ID] == nil then
		UI.registerWidget(WIDGET_ID, Economy.widget)
	end
end

return Economy
