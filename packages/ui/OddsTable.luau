--!strict
--[[
	OddsTable: exact odds for a random reward (required for paid random items).
	One row per obtainable item: rarity colour bar, name, RarityBadge, exact percentage.
	Percentages never show 0% for a non-zero chance (Format.percent).

	props:
		odds: { [itemId]: probability }   e.g. Rarity.getOdds(tableId, luck) sent from the server,
		                                  or computed from config on the client
		items: { { id: string, name: string, rarity: string } }  item defs (GameConfig.items)
		sortBy: "rarity" | "probability" | nil  ("rarity": rarest last)
		title: string?                    default "Odds"
		restricted: boolean?              show the regional notice (pass
		                                  Core.Client.state().paidRandomRestricted for Robux rolls)
		restrictedText: string?           override the notice text
		size: UDim2?, position: UDim2?, anchorPoint: Vector2?, layoutOrder: number?
		maxHeight: number?                list scrolls above this height (design px, default 320)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Format = require(script.Parent.Format)
local Odds = require(script.Parent.Odds)
local Panel = require(script.Parent.Panel)
local RarityBadge = require(script.Parent.RarityBadge)
local Theme = require(script.Parent.Theme)
local RarityTiers = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("RarityTiers"))

local e = React.createElement

export type Props = {
	odds: { [string]: number },
	items: { Odds.ItemDefLike },
	sortBy: Odds.SortBy?,
	title: string?,
	restricted: boolean?,
	restrictedText: string?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	layoutOrder: number?,
	maxHeight: number?,
}

local ROW_HEIGHT = 36
local DEFAULT_RESTRICTED_TEXT = "Paid random items are restricted in your region. "
	.. "You can still earn these rewards by playing."

local TIER_ORDER: { [string]: number } = {}
for _, def in RarityTiers.all() do
	TIER_ORDER[def.id] = def.order
end

local function Row(props: { row: Odds.OddsRow, layoutOrder: number })
	local row = props.row
	local color = (Theme.rarity(row.rarity))
	return e("Frame", {
		BackgroundColor3 = Theme.color("surfaceAlt"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		LayoutOrder = props.layoutOrder,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 8) }),
		Bar = e("Frame", {
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Size = UDim2.new(0, 6, 1, -8),
			Position = UDim2.fromOffset(4, 4),
		}, { Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }) }),
		Name = e("TextLabel", {
			Text = row.name,
			FontFace = Theme.font("bold"),
			TextSize = Theme.text.body,
			TextColor3 = Theme.color("text"),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			BackgroundTransparency = 1,
			Size = UDim2.new(0.45, -16, 1, 0),
			Position = UDim2.fromOffset(16, 0),
		}),
		Badge = if row.rarity
			then e("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.new(0.3, 0, 1, 0),
				Position = UDim2.fromScale(0.45, 0),
			}, {
				Layout = e("UIListLayout", {
					VerticalAlignment = Enum.VerticalAlignment.Center,
					HorizontalAlignment = Enum.HorizontalAlignment.Left,
				}),
				Badge = e(RarityBadge, { rarity = row.rarity }),
			})
			else nil,
		Percent = e("TextLabel", {
			Text = Format.percent(row.probability),
			FontFace = Theme.font("display"),
			TextSize = Theme.text.body,
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Right,
			BackgroundTransparency = 1,
			Size = UDim2.new(0.25, -8, 1, 0),
			Position = UDim2.fromScale(0.75, 0),
		}),
	})
end

local function OddsTable(props: Props)
	local rows = React.useMemo(function()
		return Odds.rows(props.odds, props.items, TIER_ORDER, props.sortBy)
	end, { props.odds, props.items, props.sortBy } :: { any })

	local list: { [string]: any } = {
		Layout = e("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	}
	for i, row in rows do
		list["Row_" .. row.id] = e(Row, { row = row, layoutOrder = i })
	end
	local maxHeight = props.maxHeight or 320
	local listHeight = math.min(maxHeight, #rows * (ROW_HEIGHT + 4))

	return e(Panel, {
		title = props.title or "Odds",
		size = props.size,
		position = props.position,
		anchorPoint = props.anchorPoint,
		layoutOrder = props.layoutOrder,
	}, {
		Notice = if props.restricted
			then e("TextLabel", {
				Text = props.restrictedText or DEFAULT_RESTRICTED_TEXT,
				FontFace = Theme.font("bold"),
				TextSize = Theme.text.small,
				TextWrapped = true,
				TextColor3 = Theme.color("outline"),
				BackgroundColor3 = Theme.color("warning"),
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = 1,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0, 8) }),
				Padding = e("UIPadding", {
					PaddingTop = UDim.new(0, 6),
					PaddingBottom = UDim.new(0, 6),
					PaddingLeft = UDim.new(0, 8),
					PaddingRight = UDim.new(0, 8),
				}),
			})
			else nil,
		Empty = if #rows == 0
			then e("TextLabel", {
				Text = "No odds available.",
				FontFace = Theme.font("body"),
				TextSize = Theme.text.body,
				TextColor3 = Theme.color("textMuted"),
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
				LayoutOrder = 2,
			})
			else nil,
		List = e("ScrollingFrame", {
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, listHeight),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollBarThickness = 6,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			LayoutOrder = 3,
		}, list),
	})
end

return OddsTable
