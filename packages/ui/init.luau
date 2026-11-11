--!strict
--[[
	Shared UI kit (React-lua). Required as ReplicatedStorage.UI. Games import components from
	here and never edit this package. See README.md.

	Components (React function components): Button, Panel, ItemCard, RarityBadge, Toast,
	ToastHost, Modal, CurrencyCounter, OddsTable, AutoScale, ScaledRoot.
	Pure helpers: Format, Odds, ToastQueue, Responsive, ThemeTokens, Screens, HudLayout. Theme.

	Screens (module-api.md §13): UI.registerScreen(name, component) adds or replaces a screen;
	UI.open(name, props?) / UI.close(name) / UI.isOpen(name). Default screens: Odds, Inventory,
	Mailbox (UI/screens). Open screens render in the "CoreScreens" ScreenGui (created on first open).
	HUD widgets: UI.registerWidget(id, spec | false) contributes to (or removes from) the
	framework HUD's slots (see HudLayout); UI.widgets() lists the registered ones.
]]

local UI = {}

UI.Theme = require(script.Theme)
UI.ThemeTokens = require(script.ThemeTokens)
UI.Format = require(script.Format)
UI.Odds = require(script.Odds)
UI.ToastQueue = require(script.ToastQueue)
UI.Responsive = require(script.Responsive)
UI.Primitives = require(script.Primitives)
UI.Screens = require(script.Screens)
UI.HudLayout = require(script.HudLayout)

UI.Button = require(script.Button)
UI.Panel = require(script.Panel)
UI.ItemCard = require(script.ItemCard)
UI.RarityBadge = require(script.RarityBadge)
UI.Toast = require(script.Toast)
UI.ToastHost = require(script.ToastHost)
UI.Modal = require(script.Modal)
UI.CurrencyCounter = require(script.CurrencyCounter)
UI.OddsTable = require(script.OddsTable)
UI.AutoScale = require(script.AutoScale)
UI.ScaledRoot = require(script.ScaledRoot)

local ScreenHost = require(script.ScreenHost)
UI.ScreenHost = ScreenHost.Component

-- Screen registry ------------------------------------------------------------------------------

UI.screens = UI.Screens.new()

function UI.registerScreen(name: string, component: any)
	UI.screens:register(name, component)
end

function UI.open(name: string, props: { [string]: any }?)
	ScreenHost.mount(UI.screens)
	UI.screens:open(name, props)
end

function UI.close(name: string)
	UI.screens:close(name)
end

function UI.isOpen(name: string): boolean
	return UI.screens:isOpen(name)
end

UI.registerScreen("Odds", require(script.screens.Odds))
UI.registerScreen("Inventory", require(script.screens.Inventory))
UI.registerScreen("Mailbox", require(script.screens.Mailbox))

-- HUD widget registry (read by the framework HUD) -----------------------------------------------

local widgets: { [string]: any } = {}
local widgetListeners: { [any]: boolean } = {}

function UI.registerWidget(id: string, spec: any)
	assert(type(id) == "string" and id ~= "", "UI.registerWidget: id must be a non-empty string")
	if spec ~= false then
		UI.HudLayout.checkSpec(id, spec)
	end
	widgets[id] = spec
	for fn in widgetListeners do
		task.spawn(fn)
	end
end

-- Registered widgets: { [id]: spec } (false entries are removals and are returned as overrides).
function UI.widgets(): ({ [string]: any }, { [string]: any })
	local specs, removals = {}, {}
	for id, spec in widgets do
		if spec == false then
			removals[id] = false
		else
			specs[id] = spec
		end
	end
	return specs, removals
end

function UI.onWidgetsChanged(fn: () -> ()): () -> ()
	widgetListeners[fn] = true
	return function()
		widgetListeners[fn] = nil
	end
end

return UI
