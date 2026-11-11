--!strict
--[[
	SessionLeaderboard: an example THIRD-PARTY StudWork module (module-api.md §18). It uses the
	public module API only (StudWork + ctx), exactly like the built-in kits do:
	  - its own config with defaults (GameConfig.config.SessionLeaderboard)
	  - its own save section ("sessionLeaderboard": the best session ever), replicated to its owner
	  - replicated state for everyone (the live top N) and for the owner (this session's points)
	  - an OPTIONAL dependency on Economy: when the game enables Economy, every positive
	    CurrencyChanged counts as points; without it the game reports points with api.add
	  - the shared ticker (ctx.lifecycle.onTick), a theme token, a HUD widget and a screen
	Rojo (see README.md): this file -> ReplicatedStorage.Modules.SessionLeaderboard.module,
	client/ -> ReplicatedStorage.Modules.SessionLeaderboard.client,
	server/ -> ServerScriptService.Modules.SessionLeaderboard.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
-- Economy's definition (a ModuleRef). Requiring a definition has no side effects, and an optional
-- dependency doesn't have to be enabled: ctx.isEnabled(Economy) says whether it is.
local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))

return StudWork.defineModule({
	name = "SessionLeaderboard",
	version = "0.1.0",
	framework = "^1.3.0",
	description = "Live top-N of points earned this session, plus each player's best session",
	optional = { Economy },
	config = {
		schema = {
			top = "integer(1..50)", -- rows in the shared top list
			tickSeconds = "number(1..)", -- how often the top list is rebuilt and bests are saved
			currency = "string?", -- count only this currency's gains (nil = every currency)
		},
		defaults = { top = 10, tickSeconds = 5 },
	},
	data = {
		key = "sessionLeaderboard",
		version = 1,
		default = { best = 0, sessions = 0 },
		replicate = { "best" }, -- the owner sees their best; `sessions` stays on the server
	},
	theme = {
		colors = { leaderboardHighlight = "#FFD23F" }, -- the local player's row
	},
	server = "SessionLeaderboard",
	client = "SessionLeaderboard",
})
