--!strict
-- Pure design-pixel geometry for the default ItemCard.
local Layout = {}
Layout.WIDTH = 140
Layout.ASPECT = 0.75
Layout.PADDING = 8
Layout.GAP = 4
Layout.ICON = 48
Layout.BADGE = 22
Layout.INCOME = 20
Layout.MUTATION = 20

function Layout.nameHeight(textSize: number): number
	return math.ceil(textSize * 1.25) * 2
end

function Layout.usedHeight(textSize: number): number
	return 2 * Layout.PADDING
		+ Layout.ICON
		+ Layout.nameHeight(textSize)
		+ Layout.BADGE
		+ Layout.INCOME
		+ Layout.MUTATION
		+ 4 * Layout.GAP
end

-- Design px every row except the icon needs: padding, the 2-line name, the badge, the optional
-- income and mutation rows, and the gap above each row that follows the icon.
function Layout.rowsHeight(textSize: number, hasIncome: boolean, hasMutation: boolean): number
	local rows = 2 + (if hasIncome then 1 else 0) + (if hasMutation then 1 else 0)
	return 2 * Layout.PADDING
		+ Layout.nameHeight(textSize)
		+ Layout.BADGE
		+ (if hasIncome then Layout.INCOME else 0)
		+ (if hasMutation then Layout.MUTATION else 0)
		+ rows * Layout.GAP
end

-- The icon takes the height the fixed rows leave in a card of this size (design px), never wider
-- than the card's inner width and never negative (v1.6.2: a smaller card, such as the Inventory
-- grid's, overflowed with a fixed 48-px icon).
function Layout.iconSize(
	cardWidth: number,
	cardHeight: number,
	textSize: number,
	hasIncome: boolean,
	hasMutation: boolean
): number
	local room = cardHeight - Layout.rowsHeight(textSize, hasIncome, hasMutation)
	return math.max(0, math.floor(math.min(room, cardWidth - 2 * Layout.PADDING)))
end

return table.freeze(Layout)
