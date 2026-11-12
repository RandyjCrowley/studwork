--!strict
--[[
	Pure helpers of UI.Leaderboard (zero dependencies, testable under Lune).

	  LeaderboardFormat.value(v, format?) -> string
	      "number" (default): whole numbers with thousands separators, "1,234,567" (a non-integer is
	      floored; NaN and infinities read "0"); "time": seconds as m:ss, or h:mm:ss from one hour.
	      Digits and punctuation only, so there is nothing to translate.
	  LeaderboardFormat.plan(props) -> { rows = { Entry }, pinned = Entry? }
	      which rows to draw and whether the player's own row is pinned under the list (they have a
	      value but are not in `rows`): Entry = { rank?, userId?, name?, value, isSelf, outside? }.
	      `outside` is true for a pinned row without a rank (beyond the shown rows): the component
	      shows "Top N+" (key ui.leaderboard.outsideTop) with `count` = #rows.
]]

local LeaderboardFormat = {}

export type Entry = {
	rank: number?,
	userId: number?,
	name: string?,
	value: string,
	isSelf: boolean,
	outside: boolean?,
}

local function grouped(n: number): string
	local digits = string.format("%d", math.abs(n))
	local spaced = string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")
	local out = string.reverse(spaced)
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return (if n < 0 then "-" else "") .. out
end

function LeaderboardFormat.value(v: number, format: string?): string
	if v ~= v or v == math.huge or v == -math.huge then
		return "0"
	end
	local whole = math.floor(v)
	if format == "time" then
		local seconds = math.max(0, whole)
		local h = seconds // 3600
		local m = (seconds % 3600) // 60
		local s = seconds % 60
		if h > 0 then
			return string.format("%d:%02d:%02d", h, m, s)
		end
		return string.format("%d:%02d", m, s)
	end
	return grouped(whole)
end

function LeaderboardFormat.plan(props: any): { rows: { Entry }, pinned: Entry? }
	local format = props.format
	local rows: { Entry } = {}
	local selfShown = false
	for _, row in props.rows or {} do
		local isSelf = props.selfUserId ~= nil and row.userId == props.selfUserId
		if isSelf then
			selfShown = true
		end
		table.insert(rows, {
			rank = row.rank,
			userId = row.userId,
			name = row.name,
			value = LeaderboardFormat.value(row.value, format),
			isSelf = isSelf,
		})
	end
	local pinned: Entry? = nil
	if not selfShown and props.selfUserId ~= nil and props.selfValue ~= nil then
		pinned = {
			rank = props.selfRank,
			userId = props.selfUserId,
			value = LeaderboardFormat.value(props.selfValue, format),
			isSelf = true,
			outside = props.selfRank == nil,
		}
	end
	return { rows = rows, pinned = pinned }
end

return LeaderboardFormat
