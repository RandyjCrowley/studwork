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

	Full disclosure (Types.OddsDetail from the server, Core.Client.state().odds[tableId]):
	Odds.mutationRows(detail) -> { { id, name, probability } } most likely first (zero dropped)
	Odds.outcomeRows(detail, defs, tierOrder, sortBy?) -> { OddsRow } one row per (item, mutation);
		id = "<itemId>|<mutation or ->", name = "<Mutation> <Item>" (or just the item name).
	Odds.pityLine(detail) -> string? "Guaranteed Legendary+ at least every 50 rolls"
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

local function positive(p: any): boolean
	return type(p) == "number" and p == p and p > 0
end

export type MutationRow = { id: string, name: string, probability: number }

function Odds.mutationRows(detail: any): { MutationRow }
	local rows: { MutationRow } = {}
	if type(detail) ~= "table" or type(detail.mutations) ~= "table" then
		return rows
	end
	for _, m in detail.mutations do
		if type(m) == "table" and type(m.id) == "string" and positive(m.probability) then
			table.insert(rows, {
				id = m.id,
				name = if type(m.name) == "string" then m.name else m.id,
				probability = m.probability,
			})
		end
	end
	table.sort(rows, function(a, b)
		if a.probability ~= b.probability then
			return a.probability > b.probability
		end
		return a.id < b.id
	end)
	return rows
end

function Odds.outcomeRows(
	detail: any,
	defs: { ItemDefLike },
	tierOrder: { [string]: number },
	sortBy: SortBy?
): { OddsRow }
	if type(detail) ~= "table" or type(detail.outcomes) ~= "table" then
		return {}
	end
	local mutationName: { [string]: string } = {}
	for _, m in Odds.mutationRows(detail) do
		mutationName[m.id] = m.name
	end
	local probs: { [string]: number } = {}
	local extra: { [string]: { itemId: string, mutation: string? } } = {}
	for _, o in detail.outcomes do
		if type(o) == "table" and type(o.itemId) == "string" and positive(o.probability) then
			local mutation = if type(o.mutation) == "string" then o.mutation else nil
			local id = o.itemId .. "|" .. (mutation or "-")
			probs[id] = (probs[id] or 0) + o.probability
			extra[id] = { itemId = o.itemId, mutation = mutation }
		end
	end
	local byId: { [string]: ItemDefLike } = {}
	for _, def in defs do
		byId[def.id] = def
	end
	-- reuse rows() for sorting by mapping each outcome to a pseudo def
	local pseudo: { ItemDefLike } = {}
	for id, x in extra do
		local def = byId[x.itemId]
		local itemName = if def then def.name else x.itemId
		local name = if x.mutation
			then (mutationName[x.mutation] or x.mutation) .. " " .. itemName
			else itemName
		table.insert(pseudo, { id = id, name = name, rarity = if def then def.rarity else nil :: any })
	end
	return Odds.rows(probs, pseudo, tierOrder, sortBy)
end

function Odds.pityLine(detail: any): string?
	if type(detail) ~= "table" or type(detail.pity) ~= "table" then
		return nil
	end
	local p = detail.pity
	if type(p.threshold) ~= "number" or p.threshold < 1 or type(p.minTier) ~= "string" then
		return nil
	end
	if p.threshold == 1 then
		return "Guaranteed " .. p.minTier .. "+ on every roll"
	end
	return string.format("Guaranteed %s+ at least every %d rolls", p.minTier, p.threshold)
end

-- v1.2 (N4): "Includes your luck x1.5" when the server says these odds include the player's
-- luck (detail.luckDisclosed and detail.luck ~= 1); nil otherwise. Display only: the
-- probabilities themselves already come luck-adjusted from the server.
function Odds.luckLine(detail: any): string?
	if type(detail) ~= "table" or detail.luckDisclosed ~= true then
		return nil
	end
	local luck = detail.luck
	if type(luck) ~= "number" or luck ~= luck or luck == 1 or luck <= 0 or luck == math.huge then
		return nil
	end
	local text = string.format("%.2f", luck)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return "Includes your luck x" .. text
end

return Odds
