--!nocheck
-- (v1.6.0 dogfood) A currency listed in Economy's `currencies` is a known currency: it exists with
-- balance 0 and can be granted, with no startingCurrency key (before, only primaryCurrency, a
-- startingCurrency key or a held balance were known, so every grant of it was refused). Real
-- Economy module in the multi-server sim.
local StudWork = require(game:GetService("ReplicatedStorage"):WaitForChild("Framework"))
local F = StudWork.test.sim

local function boot(paid: boolean)
	local world = F.world({
		config = {
			config = { Economy = { currencies = { "Gems" } } },
			compliance = if paid then { paidCurrencies = { "Gems" } } else nil,
		},
	})
	local server = F.server(world)
	local p = server:join(41)
	world:advanceUntil(function()
		return server:isLoaded(p)
	end, 30)
	world:advance(0.5)
	return world, server, p
end

describe("Economy: config.currencies are grantable (v1.6.0)", function()
	for _, paid in { false, true } do
		it(`a listed {if paid then "paid" else "free"} currency starts at 0 and can be granted`, function()
			local world, server, p = boot(paid)
			local Economy = server:use("Economy")
			expect(server:section(p, "economy").currency.Gems).toBe(0)
			expect(Economy.balance(p, "Gems")).toBe(0)
			expect(Economy.grant(p, 25, "test", "Gems")).toBe(true)
			expect(Economy.balance(p, "Gems")).toBe(25)
			-- an unlisted currency is still refused
			expect(Economy.grant(p, 5, "test", "Tix")).toBe(false)
			expect(#world:errors()).toBe(0)
		end)
	end
end)
