--!strict
--[[
	Pure odds-row builder for OddsTable (zero dependencies).

	Odds.rows(odds, defs, tierOrder, sortBy?) -> { OddsRow }
		odds: { [itemId]: probability } (e.g. from Rarity.getOdds, sent by the server)
		defs: { ItemDefLike } (id, name, rarity) - unknown ids still get a row named by id
		tierOrder: { [tier]: number } (1 = Common ... 7 = Secret)
		sortBy: "rarity" (default: common first, rarest last; ties by probability desc)
		        | "probability" (most likely first; ties rarest last)
	Zero / negative / NaN probabilities are dropped (not obtainable). Ties end on name then id
	so the order is deterministic.
]]

export type ItemDefLike = { id: string, name: string, rarity: string }
export type OddsRow = {
	id: string,
	name: string,
	rarity: string?,
	rarityOrder: number,
	probability: number,
}
export type SortBy = "rarity" | "probability"

local Odds = {}

function Odds.rows(
	odds: { [string]: number },
	defs: { ItemDefLike },
	tierOrder: { [string]: number },
	sortBy: SortBy?
): { OddsRow }
	local byId: { [string]: ItemDefLike } = {}
	for _, def in defs do
		byId[def.id] = def
	end
	local rows: { OddsRow } = {}
	for id, p in odds do
		if type(p) == "number" and p == p and p > 0 then
			local def = byId[id]
			local rarity = if def then def.rarity else nil
			table.insert(rows, {
				id = id,
				name = if def then def.name else id,
				rarity = rarity,
				rarityOrder = if rarity then (tierOrder[rarity] or 0) else 0,
				probability = p,
			})
		end
	end
	local mode = sortBy or "rarity"
	table.sort(rows, function(a, b)
		if mode == "probability" then
			if a.probability ~= b.probability then
				return a.probability > b.probability
			end
			if a.rarityOrder ~= b.rarityOrder then
				return a.rarityOrder < b.rarityOrder
			end
		else
			if a.rarityOrder ~= b.rarityOrder then
				return a.rarityOrder < b.rarityOrder
			end
			if a.probability ~= b.probability then
				return a.probability > b.probability
			end
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.id < b.id
	end)
	return rows
end

-- Sum of all listed probabilities (OddsTable can warn when it is far from 1).
function Odds.total(rows: { OddsRow }): number
	local sum = 0
	for _, row in rows do
		sum += row.probability
	end
	return sum
end

return Odds
