--!strict
--[[
	Pure view-model for the SessionLeaderboard widget and screen (no requires, so it is tested in
	Lune: tests/View.spec.luau). `slice` is StudWork.use(SessionLeaderboard).state():
	{ data = { best }, extra = { top = { {userId, name, earned} }, earned } }.
]]

export type Row = { rank: number, name: string, earned: number, isYou: boolean }
export type Summary = { earned: number, best: number, rows: { Row }, yourRank: number? }

local View = {}

function View.summary(slice: any, localUserId: number, limit: number?): Summary
	local data = if type(slice) == "table" and type(slice.data) == "table" then slice.data else {}
	local extra = if type(slice) == "table" and type(slice.extra) == "table" then slice.extra else {}
	local top = if type(extra.top) == "table" then extra.top else {}
	local rows: { Row } = {}
	local yourRank: number? = nil
	for i, entry in top do
		local isYou = entry.userId == localUserId
		if isYou then
			yourRank = i
		end
		if limit == nil or i <= limit then
			table.insert(
				rows,
				{ rank = i, name = tostring(entry.name), earned = entry.earned or 0, isYou = isYou }
			)
		end
	end
	local earned = if type(extra.earned) == "number" then extra.earned else 0
	local best = if type(data.best) == "number" then data.best else 0
	return { earned = earned, best = math.max(best, earned), rows = rows, yourRank = yourRank }
end

return View
