--!strict
--[[
	Default "Inventory" screen (replace with UI.registerScreen("Inventory", ...)).
	props: title?, items ({ { uid?, id, name, rarity, icon?, incomePerSec?, mutation? } }),
	onSelect?(item), emptyText?, onClose.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local ItemCard = require(script.Parent.Parent.ItemCard)
local Modal = require(script.Parent.Parent.Modal)
local Theme = require(script.Parent.Parent.Theme)

local e = React.createElement

local CARD = Vector2.new(96, 128)

return function(props: any)
	local items: { any } = props.items or {}
	local cards: { [string]: any } = {
		Grid = e("UIGridLayout", {
			CellSize = UDim2.fromOffset(CARD.X, CARD.Y),
			CellPadding = UDim2.fromOffset(8, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for i, item in items do
		cards["Item" .. i] = e(ItemCard, {
			name = item.name or item.id,
			rarity = item.rarity,
			icon = item.icon,
			incomePerSec = item.incomePerSec,
			mutation = item.mutation,
			layoutOrder = i,
			onActivated = if props.onSelect
				then function()
					props.onSelect(item)
				end
				else nil,
		})
	end
	local body = if #items == 0
		then e("TextLabel", {
			Text = props.emptyText or "Nothing here yet.",
			FontFace = Theme.font("body"),
			TextSize = Theme.text.body,
			TextColor3 = Theme.color("textMuted"),
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.fromOffset(0, 0),
			LayoutOrder = 1,
		})
		else e("ScrollingFrame", {
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, CARD.Y * 2 + 16),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			CanvasSize = UDim2.new(),
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = Theme.color("textMuted"),
			LayoutOrder = 1,
		}, cards)
	return e(
		Modal,
		{ open = true, title = props.title or "Inventory", onClose = props.onClose },
		{ Body = body }
	)
end
