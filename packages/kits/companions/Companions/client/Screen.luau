--!strict
-- The facade is resolved only from an open event/render, after client boot.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local State = require(script.Parent.State)
local Model = require(script.Parent.ScreenModel)
local Screen = {}
local context: any = nil

local function ui(): any
	return require(ReplicatedStorage:WaitForChild("UI"))
end

local function facade(): any
	return require(ReplicatedStorage:WaitForChild("Framework"))
end

local function dependencies(): (any, any)
	local modules = ReplicatedStorage:WaitForChild("Modules")
	local framework = facade()
	return framework.use(require(modules:WaitForChild("Inventory"):WaitForChild("module"))),
		framework.use(require(modules:WaitForChild("Companions"):WaitForChild("module")))
end

local function component(props: any): any
	local packages = ReplicatedStorage:WaitForChild("Packages")
	local React = require(packages:WaitForChild("React")) :: any
	local UI = ui()
	local e = React.createElement
	local Theme = UI.Theme
	local title = UI.useText("Companions.title")
	local page, setPage = React.useState(1)
	local ranks = Theme.tierOrder()
	local layout = Model.layout(Theme.touchTarget)
	local view = Model.build(
		props.inventory or {},
		context.gameConfig.items or {},
		props.equipped or {},
		ranks,
		context.config.slots,
		props.enabled == true,
		props.loaded == true,
		page
	)
	local function label(text: string, order: number): any
		return e("TextLabel", {
			Text = text,
			BackgroundTransparency = 1,
			FontFace = Theme.font("body"),
			TextSize = Theme.text.body,
			TextColor3 = Theme.color("text"),
			TextWrapped = true,
			Size = UDim2.new(1, 0, 0, Theme.touchTarget),
			LayoutOrder = order,
		})
	end
	local cards: { [string]: any } = {
		Grid = e("UIGridLayout", {
			CellSize = UDim2.fromOffset(layout.cardWidth, layout.rowHeight),
			CellPadding = UDim2.fromOffset(8, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for i, row in view.rows do
		cards[row.uid] = e("Frame", { BackgroundTransparency = 1, LayoutOrder = i }, {
			Card = e(UI.ItemCard, {
				name = row.def.name or row.def.id,
				rarity = row.def.rarity,
				icon = row.def.icon,
				mutation = row.mutation,
				size = UDim2.fromOffset(layout.cardWidth, layout.cardHeight),
			}),
			Action = e(UI.Button, {
				text = UI.text(row.key),
				disabled = row.disabled,
				size = UDim2.new(1, 0, 0, Theme.touchTarget),
				position = UDim2.fromOffset(0, layout.cardHeight + layout.gap),
				onActivated = function()
					Model.activate(row, props.actions)
				end,
			}),
		})
	end
	return e(UI.Modal, {
		open = true,
		title = title,
		onClose = props.onClose,
		size = UDim2.fromScale(layout.width, layout.height),
	}, {
		Count = label(
			UI.text("Companions.count", { equipped = view.equipped, slots = view.slots, owned = view.owned }),
			1
		),
		Best = e(UI.Button, {
			text = UI.text("Companions.equipBest"),
			disabled = not view.available,
			layoutOrder = 2,
			onActivated = function()
				Model.equipBest(view, props.actions)
			end,
		}),
		Body = if #view.rows == 0
			then label(
				UI.text(if props.enabled == false then "Companions.disabled" else "Companions.empty"),
				3
			)
			else e("ScrollingFrame", {
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, 240),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				CanvasSize = UDim2.new(),
				ScrollBarThickness = 6,
				ScrollBarImageColor3 = Theme.color("textMuted"),
				LayoutOrder = 3,
			}, cards),
		Previous = e(UI.Button, {
			text = UI.text("Companions.previous"),
			disabled = view.page <= 1,
			layoutOrder = 4,
			onActivated = function()
				setPage(view.page - 1)
			end,
		}),
		Page = label(UI.text("Companions.page", { page = view.page, pages = view.pages }), 5),
		Next = e(UI.Button, {
			text = UI.text("Companions.next"),
			disabled = view.page >= view.pages,
			layoutOrder = 6,
			onActivated = function()
				setPage(view.page + 1)
			end,
		}),
	})
end

function Screen.open()
	local UI = ui()
	local inventory, companions = dependencies()
	local framework = facade()
	local function bind(): any
		local state = framework.Client.state()
		local enabled = State.enabled(state)
		if not enabled then
			task.defer(function()
				UI.close("Companions")
			end)
		end
		return {
			inventory = inventory.read.inventory(state),
			equipped = State.equipped(state),
			enabled = enabled,
			loaded = state.loaded == true,
		}
	end
	local initial = bind()
	if not initial.enabled then
		return
	end
	UI.open("Companions", { bind = bind, actions = companions.actions })
end

local function widget(props: any): any
	local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React")) :: any
	local UI = ui()
	local text = UI.useText("Companions.open")
	if not State.enabled(props.state) then
		return nil
	end
	return React.createElement(
		UI.Button,
		{ text = text, layoutOrder = props.layoutOrder, onActivated = Screen.open }
	)
end

function Screen.init(ctx: any)
	context = ctx
end

function Screen.register(UI: any)
	if UI.screens:get("Companions") == nil then
		UI.registerScreen("Companions", component)
	end
	local specs, removals = UI.widgets()
	if specs["Companions.open"] == nil and removals["Companions.open"] == nil then
		UI.registerWidget(
			"Companions.open",
			{ slot = "topCenter", order = 30, module = "Companions", component = widget }
		)
	end
end

function Screen.start(_ctx: any)
	Screen.register(ui())
end

return Screen
