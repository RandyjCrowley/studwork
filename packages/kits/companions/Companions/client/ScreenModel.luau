--!strict
-- Pure presentation decisions. Nothing here edits replicated state.
local Model = {}
Model.PAGE_SIZE = 20

function Model.build(
	inventory: { any },
	items: { any },
	equipped: { string },
	ranks: { [string]: number },
	slots: number,
	enabled: boolean,
	loaded: boolean,
	page: number
): any
	local definitions, selected = {}, {}
	for _, def in items do
		definitions[def.id] = def
	end
	for _, uid in equipped do
		selected[uid] = true
	end
	local rows: { any } = {}
	for _, copy in inventory do
		local def = definitions[copy.itemId]
		if def and type(def.companions) == "table" and type(copy.uid) == "string" then
			table.insert(
				rows,
				{ uid = copy.uid, def = def, mutation = copy.mutation, equipped = selected[copy.uid] == true }
			)
		end
	end
	table.sort(rows, function(a: any, b: any): boolean
		local ar, br = ranks[a.def.rarity] or 0, ranks[b.def.rarity] or 0
		if ar ~= br then
			return ar > br
		end
		local ascore, bscore = a.def.companions.score or 0, b.def.companions.score or 0
		if ascore ~= bscore then
			return ascore > bscore
		end
		return a.uid < b.uid
	end)
	local pages = math.max(1, math.ceil(#rows / Model.PAGE_SIZE))
	local current = math.clamp(math.floor(page), 1, pages)
	local visible = {}
	local available = enabled and loaded
	for i = (current - 1) * Model.PAGE_SIZE + 1, math.min(current * Model.PAGE_SIZE, #rows) do
		local row = rows[i]
		row.action = if row.equipped then "unequip" else "equip"
		row.key = if row.equipped then "Companions.unequip" else "Companions.equip"
		row.disabled = not available or (not row.equipped and #equipped >= slots)
		table.insert(visible, row)
	end
	return {
		rows = visible,
		owned = #rows,
		equipped = #equipped,
		slots = slots,
		page = current,
		pages = pages,
		available = available,
	}
end

-- Modal stays inside its fitting fractions, so it never shrinks touch targets again.
function Model.layout(target: number): any
	return {
		width = 0.9,
		height = 0.85,
		cardWidth = 120,
		cardHeight = 160,
		gap = 8,
		target = target,
		rowHeight = 160 + target + 8,
	}
end

function Model.activate(row: any, actions: any)
	if not row.disabled then
		if row.action == "unequip" then
			actions.unequip(row.uid)
		else
			actions.equip(row.uid)
		end
	end
end

function Model.equipBest(view: any, actions: any)
	if view.available then
		actions.equipBest()
	end
end

return Model
