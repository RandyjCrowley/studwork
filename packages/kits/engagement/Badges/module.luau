--!strict
--[[
	Badges module definition (kit: engagement, v1.7.0). Badge definitions in config, awarded on game
	events, recorded first and sent to Roblox afterwards (never twice; failures never block play).
	Design: docs/framework/kits/badges.md. Client part ../client (toast on Awarded), net.blink
	(Awarded, server to client).

	Save section "badges" = { awarded = { [key] = { at, sent, found? } } }; `awarded` is replicated.
	Strings: Badges.awarded ("Badge earned: {name}"), Badges.title and, from config,
	Badges.badge.<key> (English default = the key until the game names it in GameConfig.strings).

	config (GameConfig.config.Badges): flag, badges, awardInStudio, ownershipCheck, retry, budget,
	infoCacheSeconds (the page's table). Badge id 0 is a placeholder (recorded, never sent).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))
local Inventory =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Inventory"):WaitForChild("module"))
local Leaderboards =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Leaderboards"):WaitForChild("module"))
local Rebirth =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Rebirth"):WaitForChild("module"))
local Streak =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Streak"):WaitForChild("module"))

return StudWork.defineModule({
	name = "Badges",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "Badge definitions, awards with dedupe and retries, an awarded signal (engagement kit)",
	optional = { Economy, Inventory, Leaderboards, Rebirth, Streak },
	config = {
		schema = {
			flag = "string?",
			badges = "{[string]: table}",
			awardInStudio = "boolean",
			ownershipCheck = "boolean",
			retry = {
				base = "number(0..)",
				factor = "number(1..)",
				max = "number(0..)",
				attempts = "integer(1..)",
			},
			budget = {
				perMinute = { base = "number(0..)", perPlayer = "number(0..)" },
				checksPerMinute = { base = "number(0..)", perPlayer = "number(0..)" },
			},
			infoCacheSeconds = "number(0..)",
		},
		defaults = {
			badges = {},
			awardInStudio = false,
			ownershipCheck = true,
			retry = { base = 5, factor = 2, max = 300, attempts = 6 },
			budget = {
				perMinute = { base = 40, perPlayer = 28 }, -- 80% of Roblox's limit: room for other callers
				checksPerMinute = { base = 10, perPlayer = 5 },
			},
			infoCacheSeconds = 3600,
		},
	},
	data = {
		key = "badges",
		version = 1,
		default = { awarded = {} },
		replicate = { "awarded" },
	},
	-- English defaults: the toast text, the title, and one name per configured badge (the key)
	strings = function(config: any): { [string]: string }
		local out: { [string]: string } = {
			["Badges.awarded"] = "Badge earned: {name}",
			["Badges.title"] = "Badges",
		}
		for key in config.badges do
			if type(key) == "string" and string.match(key, "^[%w_]+$") ~= nil and #key <= 32 then
				out["Badges.badge." .. key] = key
			end
		end
		return out
	end,
	client = "Badges",
})
