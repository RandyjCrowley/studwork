--!strict
--[[
	UI.Leaderboard (docs/framework/kits/leaderboards.md, "Client part and UI"): a ranked list.

	props:
		title: string                    the heading (already resolved: pass UI.text(key) or a literal)
		rows: { { rank, userId, name, value } }   best first
		selfUserId: number?              the local player; their row is highlighted
		selfValue: number?               their value: pinned under the list when they are not in `rows`
		selfRank: number?                their rank (nil beyond the shown rows: "Top N+" is shown)
		format: "number" | "time"?       how values read (default number; see LeaderboardFormat)
		emptyText: string?               shown when there are no rows (default: ui.leaderboard.empty)
		size: UDim2?, layoutOrder: number?

	Theme tokens only: rows alternate colors.surface / surfaceAlt, the player's own row is
	colors.leaderboardSelf (base theme, so this works with or without the module that feeds it) with
	colors.background text. Names are rendered with AutoLocalize = false (they are not translatable).
	Every label goes through UI.text (ui.leaderboard.* keys), so there is no English in this file.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Format = require(script.Parent.LeaderboardFormat)
local Panel = require(script.Parent.Panel)
local Primitives = require(script.Parent.Primitives)
local Text = require(script.Parent.Text)
local Theme = require(script.Parent.Theme)

local e = React.createElement

export type Row = { rank: number, userId: number, name: string, value: number }
export type Props = {
	title: string,
	rows: { Row },
	selfUserId: number?,
	selfValue: number?,
	selfRank: number?,
	format: ("number" | "time")?,
	emptyText: string?,
	size: UDim2?,
	layoutOrder: number?,
}

local function label(props: { [string]: any }, children: { [string]: any }?): any
	local base: { [string]: any } = {
		BackgroundTransparency = 1,
		FontFace = Theme.font("body"),
		TextSize = Theme.text.body,
		AutoLocalize = false, -- names and numbers are data, not translatable text
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextYAlignment = Enum.TextYAlignment.Center,
	}
	for k, v in props do
		base[k] = v
	end
	return e("TextLabel", base, children)
end

local function rowHeight(): number
	return math.max(Theme.touchTarget, Theme.text.body * 2)
end

local function rankText(entry: Format.Entry, shown: number): string
	if entry.outside then
		return Text.text("ui.leaderboard.outsideTop", { count = shown })
	end
	return Text.text("ui.leaderboard.rank", { rank = entry.rank or 0 })
end

local function RowView(entry: Format.Entry, index: number, shown: number, youText: string): any
	local color = if entry.isSelf
		then Theme.color("leaderboardSelf")
		elseif index % 2 == 1 then Theme.color("surfaceAlt")
		else Theme.color("surface")
	local textColor = if entry.isSelf then Theme.color("background") else Theme.color("text")
	local rankWidth = Theme.text.body * 6 -- holds "Top 100+" at the body size (UiTextFit fixture)
	return e("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, rowHeight()),
		LayoutOrder = index,
	}, {
		Corner = Primitives.corner(),
		Padding = Primitives.padding(Theme.metrics.padding / 2),
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, Theme.metrics.padding / 2),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		}),
		Rank = label({
			Text = rankText(entry, shown),
			TextColor3 = textColor,
			FontFace = Theme.font("bold"),
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(0, rankWidth, 1, 0),
			LayoutOrder = 1,
		}),
		Name = label({
			Text = if entry.name ~= nil then entry.name else youText,
			TextColor3 = textColor,
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.fromScale(0, 1),
			LayoutOrder = 2,
		}, {
			Fill = e("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill }), -- the name takes the rest of the row
		}),
		Value = label({
			Text = entry.value,
			TextColor3 = textColor,
			FontFace = Theme.font("bold"),
			TextXAlignment = Enum.TextXAlignment.Right,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 1),
			LayoutOrder = 3,
		}),
	})
end

local function Leaderboard(props: Props)
	-- useText keeps the component current on a locale change
	local youText = Text.useText("ui.leaderboard.you")
	local emptyText = Text.useText("ui.leaderboard.empty")
	local plan = Format.plan(props)
	local shown = #plan.rows
	local children: { [string]: any } = {}
	for i, entry in plan.rows do
		children[`Row{i}`] = RowView(entry, i, shown, youText)
	end
	if shown == 0 then
		children.Empty = label({
			Text = props.emptyText or emptyText,
			TextColor3 = Theme.color("textMuted"),
			TextWrapped = true,
			Size = UDim2.new(1, 0, 0, rowHeight()),
			LayoutOrder = 1,
		})
	end
	if plan.pinned ~= nil then
		children.Pinned = RowView(plan.pinned, shown + 1, shown, youText)
	end
	return e(Panel, {
		title = props.title,
		size = props.size,
		layoutOrder = props.layoutOrder,
	}, children)
end

return Leaderboard
