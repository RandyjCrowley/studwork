--!strict
--[[
	OddsTable: exact odds for a random reward (required for paid random items).
	One row per obtainable item: rarity colour bar, name, RarityBadge, exact percentage.
	Percentages never show 0% for a non-zero chance (Format.percent).

	props:
		detail: Types.OddsDetail?         full disclosure from the SERVER (preferred):
		                                  Core.Client.state().odds[tableId]. Renders the item odds,
		                                  mutation lines ("Rainbow 3%"), every final (item, mutation)
		                                  outcome and the pity line. Takes precedence over `odds`.
		                                  When detail.luckDisclosed and detail.luck ~= 1 a line
		                                  "Includes your luck x1.5" is shown above the items (the
		                                  probabilities are the server's luck-adjusted ones).
		odds: { [itemId]: probability }?  legacy: per-item odds only (e.g. Rarity.getOdds)
		items: { { id: string, name: string, rarity: string } }  item defs (GameConfig.items)
		sortBy: "rarity" | "probability" | nil  ("rarity": rarest last)
		title: string | false              default "Odds"; false omits embedded heading
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
local OddsLayout = require(script.Parent.OddsLayout)
local Panel = require(script.Parent.Panel)
local RarityBadge = require(script.Parent.RarityBadge)
local TextFit = require(script.Parent.TextFit)
local Theme = require(script.Parent.Theme)
local WrappedText = require(script.Parent.WrappedText)

local e = React.createElement

export type Props = {
	detail: any?, -- Types.OddsDetail
	odds: { [string]: number }?,
	items: { Odds.ItemDefLike },
	sortBy: Odds.SortBy?,
	title: (string | boolean)?,
	restricted: boolean?,
	restrictedText: string?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	layoutOrder: number?,
	maxHeight: number?,
}

local ROW_HEIGHT = OddsLayout.ROW_HEIGHT
local DEFAULT_RESTRICTED_TEXT = "Paid random items are restricted in your region. "
	.. "You can still earn these rewards by playing."

-- Text never clips (v1.6.1): every cell is a Scale fraction of the row (OddsLayout.columns) and
-- every text is TextScaled with a UITextSizeConstraint from the theme (min = Theme.text.min).
local function minText(maxSize: number): number
	return TextFit.fixedLabel(maxSize, Theme.text.min).MinTextSize :: number
end

-- Cells are one ROW_HEIGHT tall, not a fraction of the row: an expanded row (tap to show the full
-- name, v1.6.2) grows below them, and a Scale height let the 2-line name grow a third line over
-- the full-name line (Studio finding).
local function cell(col: OddsLayout.Column): (UDim2, UDim2)
	return UDim2.new(col.scale, col.offset, 0, ROW_HEIGHT), UDim2.new(col.x, col.xOffset, 0, 0)
end

local function Row(props: { row: Odds.OddsRow, layoutOrder: number })
	local expanded, setExpanded = React.useState(false)
	local fullHeight, setFullHeight = React.useState(ROW_HEIGHT)
	local row = props.row
	local color = (Theme.rarity(row.rarity))
	local cols = OddsLayout.columns
	local nameSize, namePos = cell(cols.name)
	local badgeSize, badgePos = cell(cols.badge)
	local pctSize, pctPos = cell(cols.percent)
	return e("Frame", {
		BackgroundColor3 = Theme.color("surfaceAlt"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, if expanded then ROW_HEIGHT + fullHeight else ROW_HEIGHT),
		LayoutOrder = props.layoutOrder,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 8) }),
		Bar = e("Frame", {
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Size = UDim2.new(0, 6, 1, -8),
			Position = UDim2.fromOffset(4, 4),
		}, { Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }) }),
		Name = e("TextButton", {
			AutoButtonColor = false,
			Selectable = true,
			[React.Event.Activated] = function()
				setExpanded(not expanded)
			end,
			Text = row.name,
			FontFace = Theme.font("bold"),
			TextSize = Theme.text.body,
			TextScaled = false, -- names keep a readable fixed size
			TextWrapped = true,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = Theme.color("text"),
			TextXAlignment = Enum.TextXAlignment.Left,
			BackgroundTransparency = 1,
			Size = nameSize,
			Position = namePos,
		}),
		FullName = if expanded
			then e("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -16, 0, fullHeight),
				Position = UDim2.new(0, 16, 0, ROW_HEIGHT),
			}, {
				Text = e(WrappedText, {
					text = row.name,
					textSize = "body",
					font = "bold",
					color = "text",
					onHeight = setFullHeight,
				}),
			})
			else nil,
		Badge = if row.rarity
			then e("Frame", {
				BackgroundTransparency = 1,
				Size = badgeSize,
				Position = badgePos,
			}, {
				Layout = e("UIListLayout", {
					VerticalAlignment = Enum.VerticalAlignment.Center,
					HorizontalAlignment = Enum.HorizontalAlignment.Left,
				}),
				-- a sized badge is TextScaled with a theme constraint: "LEGENDARY" fits a phone row
				Badge = e(RarityBadge, {
					rarity = row.rarity,
					size = UDim2.new(1, 0, 0, OddsLayout.BADGE_HEIGHT),
				}),
			})
			else nil,
		Percent = e("TextLabel", {
			Text = Format.percent(row.probability),
			FontFace = Theme.font("display"),
			TextSize = Theme.text.body,
			TextScaled = true, -- fixed-width cell: fits for any theme font (v1.3.0, TextFit)
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Right,
			BackgroundTransparency = 1,
			Size = pctSize,
			Position = pctPos,
		}, {
			Fit = e("UITextSizeConstraint", {
				MinTextSize = minText(Theme.text.body),
				MaxTextSize = Theme.text.body,
			}),
		}),
	})
end

local HEADER_HEIGHT = 24

local function Header(props: { text: string, layoutOrder: number })
	return e(WrappedText, {
		text = props.text,
		font = "bold",
		textSize = "small",
		color = "textMuted",
		layoutOrder = props.layoutOrder,
	})
end

local function OddsTable(props: Props)
	local detail = props.detail
	local model = React.useMemo(function()
		local itemOdds = if type(detail) == "table" and type(detail.items) == "table"
			then detail.items
			else (props.odds or {})
		return {
			items = Odds.rows(itemOdds, props.items, Theme.tierOrder(), props.sortBy),
			mutations = Odds.mutationRows(detail),
			outcomes = Odds.outcomeRows(detail, props.items, Theme.tierOrder(), props.sortBy),
			pity = Odds.pityLine(detail),
			luck = Odds.luckLine(detail),
		}
	end, { detail, props.odds, props.items, props.sortBy } :: { any })
	local rows = model.items

	local list: { [string]: any } = {
		Layout = e("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	}
	local order = 0
	local height = 0
	local function add(key: string, element: any, h: number)
		order += 1
		list[key] = element
		height += h + 4
	end
	local function addHeader(key: string, text: string)
		add(key, e(Header, { text = text, layoutOrder = order + 1 }), HEADER_HEIGHT)
	end
	if model.luck then
		addHeader("Luck", model.luck)
	end
	if model.pity then
		addHeader("Pity", model.pity)
	end
	local showSections = #model.mutations > 0
	if showSections then
		addHeader("ItemsHeader", "Items")
	end
	for _, row in rows do
		add("Row_" .. row.id, e(Row, { row = row, layoutOrder = order + 1 }), ROW_HEIGHT)
	end
	if showSections then
		local parts = {}
		for _, m in model.mutations do
			table.insert(parts, m.name .. " " .. Format.percent(m.probability))
		end
		addHeader("MutationsHeader", "Mutations: " .. table.concat(parts, ", "))
		addHeader("OutcomesHeader", "All outcomes")
		for _, row in model.outcomes do
			add("Outcome_" .. row.id, e(Row, { row = row, layoutOrder = order + 1 }), ROW_HEIGHT)
		end
	end
	local maxHeight = props.maxHeight or 320
	local listHeight = math.min(maxHeight, height)

	return e(Panel, {
		title = if props.title == false then nil else (props.title or "Odds"),
		size = props.size,
		position = props.position,
		anchorPoint = props.anchorPoint,
		layoutOrder = props.layoutOrder,
	}, {
		Notice = if props.restricted
			then e(WrappedText, {
				text = props.restrictedText or DEFAULT_RESTRICTED_TEXT,
				font = "bold",
				textSize = "small",
				color = "outline",
				backgroundColor = "warning",
				padding = 8,
				layoutOrder = 1,
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
