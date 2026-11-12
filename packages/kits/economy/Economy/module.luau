--!strict
--[[
	Economy module definition (kit: economy). v1.3.0: a real StudWork module; the
	server part is ../server/Economy (README there: api, txApi, extensions, income rules).

	config (config.Economy; keys unchanged from v1.2 `balance`):
	  primaryCurrency      the HUD / default currency                         default "Coins"
	  startingCurrency     { [currency]: amount } granted on the first join   default none
	  income.tickSeconds   income is paid every this many seconds              default 1
	  income.source        "owned" (every inventory copy earns) | "displayed"
	                       (only copies on the plot earn; needs Plot)          default "owned"
	  multiplierStacking   "multiply" | "add" (1 + Σ(f - 1))                   default "multiply"
	  currencies           further currencies Economy OWNS besides primaryCurrency default none
	Paid (Robux-buyable) currencies are framework config: GameConfig.compliance.paidCurrencies.
	Economy registers the compliance spender (ctx.compliance.registerCurrencySpender) only for the
	paid currencies it owns: primaryCurrency and `currencies` (v1.3.1, R20). Any other paid
	currency needs its own owner module, or boot fails (module-api §19.10). Since v1.6.0 a
	`currencies` entry is also a known currency like the primary: every player has it (balance 0
	unless startingCurrency says otherwise) and grant/spend accept it.
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
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Items = require(Modules:WaitForChild("Items"):WaitForChild("module"))
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))

return StudWork.defineModule({
	name = "Economy",
	version = "1.3.0",
	framework = "^1.3.0",
	description = "Currencies, item income, multipliers and boosts (economy kit)",
	client = "Economy",
	optional = { Items, Inventory },
	config = {
		schema = {
			primaryCurrency = { type = "string", description = "HUD / default currency" },
			currencies = {
				type = "{string}?",
				description = "further currencies Economy owns besides primaryCurrency (each starts at 0 and is grantable; a paid currency gets Economy's spender only if it is one of these)",
			},
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
