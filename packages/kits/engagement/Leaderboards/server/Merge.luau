--!strict
--[[
	Leaderboards: the value rules (pure, no yielding; specs in tests/LeaderboardsPure.spec.luau).

	  Merge.normalize(value) -> number?          a finite number, floored; nil for anything else
	  Merge.better(order, a, b) -> number        the better of two values: "desc" the larger, "asc" the smaller
	  Merge.combine(mode, order, old, value)     how a new value joins the player's saved one:
	                                             "max" the better, "set" the latest, "sum" adds
	  Merge.stored(mode, order, old, total)      what a store keeps for `total` given the stored `old`
	                                             (never worse: a stale re-send can't undo a better value;
	                                             "set" overwrites)
	  Merge.beatsCut(order, value, cut) -> boolean   `value` would place above a full board's last row
	  Merge.sortRows(order, rows)                orders rows { u, n, v } best first (ties by user id)
	  Merge.mergeRows(order, topN, lists) -> rows    several lists of rows -> the best topN, one row per user
	  Merge.indexOf(rows, userId) -> number?     the 1-based position of a user
]]

local Merge = {}

export type Row = { u: number, n: string, v: number }

function Merge.normalize(value: any): number?
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return math.floor(value)
end

function Merge.better(order: string, a: number, b: number): number
	if order == "asc" then
		return math.min(a, b)
	end
	return math.max(a, b)
end

function Merge.combine(mode: string, order: string, old: number?, value: number): number
	if mode == "set" then
		return value
	elseif mode == "sum" then
		return (old or 0) + value
	end
	return if old == nil then value else Merge.better(order, old, value)
end

function Merge.stored(mode: string, order: string, old: number?, total: number): number
	if mode == "set" then
		return total
	elseif old == nil then
		return total
	elseif mode == "sum" then
		return math.max(old, total)
	end
	return Merge.better(order, old, total)
end

function Merge.beatsCut(order: string, value: number, cut: number): boolean
	if order == "asc" then
		return value < cut
	end
	return value > cut
end

function Merge.sortRows(order: string, rows: { Row })
	table.sort(rows, function(a: Row, b: Row): boolean
		if a.v ~= b.v then
			if order == "asc" then
				return a.v < b.v
			end
			return a.v > b.v
		end
		return a.u < b.u
	end)
end

function Merge.mergeRows(order: string, topN: number, lists: { { Row } }): { Row }
	local byUser: { [number]: Row } = {}
	for _, list in lists do
		for _, row in list do
			local seen = byUser[row.u]
			if seen == nil or Merge.better(order, seen.v, row.v) == row.v and row.v ~= seen.v then
				byUser[row.u] = row
			end
		end
	end
	local out: { Row } = {}
	for _, row in byUser do
		table.insert(out, row)
	end
	Merge.sortRows(order, out)
	while #out > topN do
		table.remove(out)
	end
	return out
end

function Merge.indexOf(rows: { Row }, userId: number): number?
	for i, row in rows do
		if row.u == userId then
			return i
		end
	end
	return nil
end

return Merge
