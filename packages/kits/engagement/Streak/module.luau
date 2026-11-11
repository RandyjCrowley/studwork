--!strict
--[[
	Streak module definition (kit: engagement). core-v1.3.0 Phase 1: a real module; the server
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
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))

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
