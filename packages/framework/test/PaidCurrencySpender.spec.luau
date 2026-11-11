--!nocheck
--[[
	core-v1.3.1 R20 (module-api.md §19.10): boot fails closed when a currency listed in
	GameConfig.compliance.paidCurrencies has no spender registered through
	ctx.compliance.registerCurrencySpender once every module has run init and start.
	Driven through the public testkit (StudWork.test.boot / StudWork.test.harness).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))

local Plain =
	StudWork.defineModule({ name = "PlainR20", server = "PlainR20", version = "1.0.0", framework = "^1.3.0" })
local plainPart = { init = function() end }

-- a third-party currency owner that registers its spender in start (still in time)
local Wallet = StudWork.defineModule({
	name = "WalletR20",
	server = "WalletR20",
	version = "1.0.0",
	framework = "^1.3.0",
})
local walletPart = {
	start = function(ctx)
		ctx.compliance.registerCurrencySpender("Tokens", function()
			return true
		end)
	end,
}

describe("R20: every paid currency has a registered spender at boot", function()
	it("a paid currency with no spender fails boot, naming the currency", function()
		local h, err = StudWork.test.boot({
			modules = { Plain },
			servers = { PlainR20 = plainPart },
			compliance = { paidCurrencies = { "Gems" } },
		})
		expect(h).toBeNil()
		expect(tostring(err)).toContain("compliance.paidCurrencies lists 'Gems'")
		expect(tostring(err)).toContain("ctx.compliance.registerCurrencySpender")
		expect(tostring(err)).toContain("boot failed")
	end)

	it("names the missing one when only some currencies have a spender", function()
		local h, err = StudWork.test.boot({
			modules = { Wallet },
			servers = { WalletR20 = walletPart },
			compliance = { paidCurrencies = { "Tokens", "Gems" } },
		})
		expect(h).toBeNil()
		expect(tostring(err)).toContain("lists 'Gems'")
		expect(string.find(tostring(err), "lists 'Tokens'", 1, true)).toBeNil()
	end)

	it("a spender registered in start counts", function()
		local h, err = StudWork.test.boot({
			modules = { Wallet },
			servers = { WalletR20 = walletPart },
			compliance = { paidCurrencies = { "Tokens" } },
		})
		expect(err).toBeNil()
		expect(h ~= nil).toBe(true)
	end)

	it("Economy enabled with a paid currency it owns boots (Economy registers its spender)", function()
		-- core-v1.3.1 final review High 1: Economy owns primaryCurrency + config.Economy.currencies only
		local h, err = StudWork.test.boot({
			modules = { Economy },
			config = { Economy = { currencies = { "Gems" } } },
			compliance = { paidCurrencies = { "Gems" } },
		})
		expect(err).toBeNil()
		expect(h ~= nil).toBe(true)
		local h2, err2 = StudWork.test.boot({
			modules = { Economy },
			compliance = { paidCurrencies = { "Coins" } }, -- the default primaryCurrency
		})
		expect(err2).toBeNil()
		expect(h2 ~= nil).toBe(true)
	end)

	it("Economy doesn't own every listed currency: a typo'd paid currency still fails boot", function()
		-- final review High 1 repro: paidCurrencies = { "Gemz_TYPO" } used to boot (Economy registered a
		-- spender for every listed currency)
		local h, err = StudWork.test.boot({
			modules = { Economy },
			compliance = { paidCurrencies = { "Coins", "Gemz_TYPO" } },
		})
		expect(h).toBeNil()
		expect(tostring(err)).toContain("compliance.paidCurrencies lists 'Gemz_TYPO'")
	end)

	it("a third-party module can own a paid currency alongside Economy", function()
		-- final review Medium 2: 'currency 'Tokens' already has a spender (owned by Economy)'
		local h, err = StudWork.test.boot({
			modules = { Economy, Wallet },
			servers = { WalletR20 = walletPart },
			compliance = { paidCurrencies = { "Coins", "Tokens" } },
		})
		expect(err).toBeNil()
		expect(h ~= nil).toBe(true)
	end)

	it("an empty or missing paidCurrencies list boots", function()
		local h1, err1 = StudWork.test.boot({
			modules = { Plain },
			servers = { PlainR20 = plainPart },
			compliance = { paidCurrencies = {} },
		})
		expect(err1).toBeNil()
		expect(h1 ~= nil).toBe(true)
		local h2, err2 = StudWork.test.boot({ modules = { Plain }, servers = { PlainR20 = plainPart } })
		expect(err2).toBeNil()
		expect(h2 ~= nil).toBe(true)
	end)
end)
