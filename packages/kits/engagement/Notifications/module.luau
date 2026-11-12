--!strict
--[[
	Notifications module definition (kit: engagement, v1.7.0). Experience notifications: an opt-in
	prompt at a good moment, templates in config, sends triggered by game events, a due list for
	future sends. Design: docs/framework/kits/notifications.md. Server part ../server (api, due list,
	sends through ctx.openCloud), client part ../client (the prompt through Roblox's service),
	net.blink (PromptOptIn, OptInShown, SetUtcOffset).

	Save section "notifications" = { lastPromptAt, prompts, sessions, utcOffset?, promptRequest?,
	lastLaunchDay }, not replicated. Scheduled entries live in the shared ledger, not the save.

	config (GameConfig.config.Notifications): flag, secret, sendInStudio, templates, optIn, limits,
	quiet, schedule, retry (the page's table; every number is config).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Streak =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Streak"):WaitForChild("module"))

return StudWork.defineModule({
	name = "Notifications",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "Experience notifications: opt-in prompt, templates, scheduled sends (engagement kit)",
	optional = { Streak },
	config = {
		schema = {
			flag = "string?",
			secret = "string",
			sendInStudio = "boolean",
			templates = "{[string]: table}",
			optIn = {
				minSessionSeconds = "number(0..)",
				minSessions = "integer(0..)",
				cooldownDays = "number(0..)",
				maxPrompts = "integer(0..)",
				onSuggest = "boolean",
			},
			limits = {
				perPlayerPerDay = "integer(1..)",
				minGapHours = "number(0..)",
				perServerPerMinute = "integer(1..)",
			},
			quiet = {
				startHour = "integer(0..23)",
				endHour = "integer(0..23)",
				defaultUtcOffsetHours = "number(-14..14)",
			},
			schedule = {
				shards = "integer(1..32)",
				pollSeconds = "number(1..)",
				pollsPerShardPerMinute = "number(1..)",
				batch = "integer(1..200)",
				leaseSeconds = "number(45..600)",
				staleAfterHours = "number(0..)",
				maxAheadHours = "number(1..)",
				maxPerPlayer = "integer(1..)",
			},
			retry = {
				base = "number(0..)",
				factor = "number(1..)",
				max = "number(0..)",
				attempts = "integer(1..)",
			},
		},
		defaults = {
			secret = "OpenCloudNotifications",
			sendInStudio = false,
			templates = {},
			optIn = {
				minSessionSeconds = 180,
				minSessions = 1,
				cooldownDays = 30,
				maxPrompts = 3,
				onSuggest = true,
			},
			limits = { perPlayerPerDay = 1, minGapHours = 20, perServerPerMinute = 60 },
			quiet = { startHour = 22, endHour = 8, defaultUtcOffsetHours = 0 },
			schedule = {
				shards = 4,
				pollSeconds = 30,
				pollsPerShardPerMinute = 20,
				batch = 20,
				leaseSeconds = 90,
				staleAfterHours = 12,
				maxAheadHours = 168,
				maxPerPlayer = 5,
			},
			retry = { base = 30, factor = 2, max = 900, attempts = 4 },
		},
	},
	data = {
		key = "notifications",
		version = 1,
		default = { lastPromptAt = 0, prompts = 0, sessions = 0, lastLaunchDay = 0 },
		replicate = false,
	},
	client = "Notifications",
})
