--!strict
--[[
	Streak module definition (kit: engagement). v1.3.0: a real module; the server
	part is ../server/Streak. Save section "streak" = { streak = { day, lastDay } }: the v1.2
	field, unchanged (FrameworkSection.V12_MAP), replicated to the owning client.

	config (GameConfig.config.Streak.streak)
	  graceHours       number     hours after a missed day ends in which the streak still
	                              continues (default 6, the value every v1.2 game used)
	  utcOffsetHours   number     time zone the days are counted in, -14..14 (default 0 = UTC,
	                              the v1.2 behaviour)
	  rewards          table?     { { day, amount, currency? } } granted through the optional
	                              Economy module
	  loopAfter        integer?   the rewards table wraps after this day

	api (v1.7.0 adds expiresAt(player) -> number?: the unix time the streak ends without a visit)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))

-- The server API (`StudWork.use(Streak)`). `expiresAt` is v1.7.0 (additive): the Notifications kit
-- uses it for the "your streak ends soon" reminder.
export type StreakApi = {
	onDaily: (handler: (player: any, streakDay: number) -> ()) -> any,
	get: (player: any) -> { day: number, lastDay: number },
	expiresAt: (player: any) -> number?,
	signals: { StreakAdvanced: any },
}

return StudWork.defineModule({
	name = "Streak",
	version = "1.3.0",
	framework = "^1.3.0",
	description = "Daily login streak with rewards (engagement kit)",
	optional = { Economy },
	config = {
		schema = {
			streak = {
				graceHours = "number(0..)",
				utcOffsetHours = "number(-14..14)",
				rewards = "table?",
				loopAfter = "integer(1..)?",
			},
		},
		defaults = { streak = { graceHours = 6, utcOffsetHours = 0 } },
	},
	data = {
		key = "streak",
		version = 1,
		default = { streak = { day = 0, lastDay = 0 } },
		replicate = { "streak" },
	},
})
