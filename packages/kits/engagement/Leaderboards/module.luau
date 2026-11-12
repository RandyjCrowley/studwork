--!strict
--[[
	Leaderboards module definition (kit: engagement, v1.7.0). Global all-time boards
	(OrderedDataStore through ctx.data.ordered) and daily or weekly boards (sorted maps through
	ctx.data.sortedMap), a top N shared by every server, the player's own rank, UI.Leaderboard.
	Design: docs/framework/kits/leaderboards.md. No net.blink: values come only from the server and
	the rows travel as replicated extra (boards, mine).

	Save section "leaderboards" = { values, periods, dirty }, not replicated.
	Strings: Leaderboards.title and, from config, Leaderboards.board.<boardId> (English default =
	the board id until the game sets one in GameConfig.strings). No module theme: the player's own
	row colour (colors.leaderboardSelf) is in the base theme.

	config (GameConfig.config.Leaderboards): flag, boards, refreshSeconds, topReadsPerMinute,
	writeSeconds, utcOffsetHours, weekStartsOn, cutToTop, previousPeriod, periodGraceHours, names,
	backoff (the page's table).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))
local Rebirth =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Rebirth"):WaitForChild("module"))
local Streak =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Streak"):WaitForChild("module"))

return StudWork.defineModule({
	name = "Leaderboards",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "All-time and daily/weekly leaderboards shared by every server (engagement kit)",
	optional = { Economy, Rebirth, Streak },
	config = {
		schema = {
			flag = "string?",
			boards = "{[string]: table}",
			refreshSeconds = "number(1..)",
			topReadsPerMinute = "number(1..)",
			writeSeconds = "number(1..)",
			utcOffsetHours = "number(-14..14)",
			weekStartsOn = '"monday"|"sunday"',
			cutToTop = "boolean",
			previousPeriod = "boolean",
			periodGraceHours = "number(0..24)",
			names = { cacheSeconds = "number(0..)" },
			backoff = { base = "number(0..)", factor = "number(1..)", max = "number(0..)" },
		},
		defaults = {
			boards = {},
			refreshSeconds = 60,
			topReadsPerMinute = 6000,
			writeSeconds = 120,
			utcOffsetHours = 0,
			weekStartsOn = "monday",
			cutToTop = true,
			previousPeriod = true,
			periodGraceHours = 24,
			names = { cacheSeconds = 3600 },
			backoff = { base = 60, factor = 2, max = 600 },
		},
	},
	data = {
		key = "leaderboards",
		version = 1,
		default = { values = {}, periods = {}, dirty = {} },
		replicate = false,
	},
	-- English defaults: the module's title, and one title per configured board (the board id)
	strings = function(config: any): { [string]: string }
		local out: { [string]: string } = { ["Leaderboards.title"] = "Leaderboards" }
		for boardId in config.boards do
			if type(boardId) == "string" and string.match(boardId, "^[%w_]+$") ~= nil and #boardId <= 24 then
				out["Leaderboards.board." .. boardId] = boardId
			end
		end
		return out
	end,
	client = "Leaderboards",
})
