--!strict
--[[
	Pure layout rules for UI.OddsTable rows (v1.6.1, playtest finding: long rarity labels such as
	"LEGENDARY" or "MYTHICAL" overflowed the badge cell, and long item names were cut off with "...").

	Every row cell is a Scale fraction of the row width (no fixed pixel widths), and every text cell
	is TextScaled (+ TextWrapped for names) with a UITextSizeConstraint from the theme
	(min = Theme.text.min, max = the cell's theme size). So a label shrinks instead of clipping.

	The narrowest row the table is ever laid out in (design px, before Modal's UIScale which
	shrinks everything uniformly) is MIN_ROW_WIDTH: the Modal's minimum width (320) minus the
	panel padding on both sides (2 x 12) and the scroll bar (6). Viewports checked (landscape):
	1280x720 (Studio default stand-in), 667x375 (small phone), 926x428 (large phone), 1024x768
	(tablet), plus 375x667 / 428x926 portrait; none lays a row out narrower than MIN_ROW_WIDTH.

	OddsLayout.columns            { name, badge, percent } = { scale, offset, x } per cell
	OddsLayout.cellWidth(col, rowWidth) -> number  px width of a column in a row of that width
	OddsLayout.estimateWidth(text, textSize) -> number  conservative px width of one line of
	                              text (GLYPH_WIDTH x size per character, wide display fonts)
]]

local OddsLayout = {}

OddsLayout.MIN_ROW_WIDTH = 320 - 2 * 12 - 6
OddsLayout.ROW_HEIGHT = 48
OddsLayout.BADGE_HEIGHT = 22
OddsLayout.BADGE_PADDING = 8 -- each side
-- Average glyph advance as a fraction of the text size, upper-cased, for a wide display font
-- (LuckiestGuy/Fredoka One measure about 0.55-0.6); deliberately conservative.
OddsLayout.GLYPH_WIDTH = 0.65

export type Column = { scale: number, offset: number, x: number, xOffset: number }

OddsLayout.columns = table.freeze({
	name = table.freeze({ scale = 0.38, offset = -16, x = 0, xOffset = 16 }),
	badge = table.freeze({ scale = 0.37, offset = -4, x = 0.38, xOffset = 0 }),
	percent = table.freeze({ scale = 0.25, offset = -8, x = 0.75, xOffset = 0 }),
})

function OddsLayout.cellWidth(col: Column, rowWidth: number): number
	return col.scale * rowWidth + col.offset
end

function OddsLayout.estimateWidth(text: string, textSize: number): number
	local n: number = utf8.len(text) or #text
	return n * OddsLayout.GLYPH_WIDTH * textSize
end

return table.freeze(OddsLayout)
