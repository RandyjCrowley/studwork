--!strict
--[[
	Economy module definition (kit: economy). core-v1.3.0 Phase 1: a real StudWork module; the
	server part is ../server/Economy (README there: api, txApi, extensions, income rules).

	config (config.Economy; keys unchanged from v1.2 `balance`):
	  primaryCurrency      the HUD / default currency                         default "Coins"
	  startingCurrency     { [currency]: amount } granted on the first join   default none
	  income.tickSeconds   income is paid every this many seconds              default 1
	  income.source        "owned" (every inventory copy earns) | "displayed"
	                       (only copies on the plot earn; needs Plot)          default "owned"
	  multiplierStacking   "multiply" | "add" (1 + Σ(f - 1))                   default "multiply"
	Paid (Robux-buyable) currencies are framework config: GameConfig.compliance.paidCurrencies.
	data: section `economy` = { currency = { [id]: number }, multipliers = { [id]: { mult,
	expiresAt? } } } (the v1.2 fields; FrameworkSection.V12_MAP splits a v1.2 save into it).
	itemFields: item.economy.incomePerSec (an item without it earns nothing),
	mutation.economy.incomeMultiplier (default 1).
	optional: Items (mutation multipliers), Inventory (item income). Plot reaches Economy, not the
	other way round (extensions.displayedSource), so the kits' definitions never require each
	other in a cycle.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Collection = ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Collection")
local Items = require(Collection:WaitForChild("Items"))
local Inventory = require(Collection:WaitForChild("Inventory"))

return StudWork.defineModule({
	name = "Economy",
	version = "1.3.0",
	framework = "^1.3.0",
	description = "Currencies, item income, multipliers and boosts (economy kit)",
	optional = { Items, Inventory },
	config = {
		schema = {
			primaryCurrency = { type = "string", description = "HUD / default currency" },
			startingCurrency = {
				type = "{[string]: number}?",
				description = "balances granted on a player's first join",
			},
			income = {
				tickSeconds = { type = "number(0.05..)", description = "seconds between income payouts" },
				source = {
					type = '"owned"|"displayed"',
					description = '"owned": every inventory copy earns; "displayed": only copies on the plot',
				},
			},
			multiplierStacking = {
				type = '"multiply"|"add"',
				description = "how multipliers combine: product, or 1 + sum(f - 1)",
			},
		},
		defaults = {
			primaryCurrency = "Coins",
			income = { tickSeconds = 1, source = "owned" },
			multiplierStacking = "multiply",
		},
	},
	data = {
		key = "economy",
		version = 1,
		default = { currency = {}, multipliers = {} },
		replicate = { "currency", "multipliers" },
	},
	itemFields = {
		item = { economy = { incomePerSec = "number?" } },
		mutation = { economy = { incomeMultiplier = "number?" } },
	},
})
