--!strict
-- Free promotion definitions. Server-only catalogs belong in ServerConfig.Codes.definitions.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Rules = require(script.Parent:WaitForChild("shared"):WaitForChild("Rules"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local Rarity = require(Modules:WaitForChild("Rarity"):WaitForChild("module"))
local Rebirth = require(Modules:WaitForChild("Rebirth"):WaitForChild("module"))

return StudWork.defineModule({
	name = "Codes",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "Free promotion rewards with durable global caps",
	optional = { Economy, Inventory, Rarity, Rebirth },
	config = {
		schema = {
			flag = "string?",
			definitions = "{table}",
			maxLength = "integer(1..64)",
			maxDefinitions = "integer(1..256)",
			maxRewards = "integer(1..16)",
			maxRequirements = "integer(1..16)",
			maxGlobalUses = "integer(1..10000)",
			failureLimit = "integer(1..)",
			failureWindowSeconds = "number(1..)",
			lockoutSeconds = "number(1..)",
			rate = { rate = "number(0..)", burst = "integer(1..)" },
			sharedOpsPerMinute = "integer(4..)",
			live = {
				enabled = "boolean",
				key = "string",
				refreshSeconds = "number(5..600)",
				maxEntries = "integer(1..256)",
			},
			maxNewPlayerSeconds = "number(0..)",
		},
		defaults = Rules.DEFAULTS,
	},
	data = {
		key = "codes",
		version = 1,
		default = { redeemed = {}, pending = {}, sequence = 0 },
		replicate = false,
		sanitize = Rules.sanitize,
	},
	strings = function(config: any): { [string]: string }
		local valid = Rules.validateCatalog(config.definitions, config)
		assert(valid, "Codes: invalid configured catalog")
		return {
			["Codes.title"] = "Promo codes",
			["Codes.placeholder"] = "Enter a code",
			["Codes.redeem"] = "Redeem",
			["Codes.close"] = "Close",
			["Codes.odds"] = "Reward odds",
			["Codes.pending"] = "Checking code…",
			["Codes.ok"] = "Reward redeemed!",
			["Codes.invalid"] = "That code is not valid.",
			["Codes.expired"] = "That code has expired.",
			["Codes.not_yet"] = "That code is not active yet.",
			["Codes.already_used"] = "You have already used that code.",
			["Codes.limit_reached"] = "That code has reached its use limit.",
			["Codes.not_eligible"] = "You are not eligible for that code.",
			["Codes.try_later"] = "Please try again later.",
		}
	end,
	client = "Codes",
})
