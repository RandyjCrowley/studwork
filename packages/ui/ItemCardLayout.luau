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

return table.freeze(Layout)
