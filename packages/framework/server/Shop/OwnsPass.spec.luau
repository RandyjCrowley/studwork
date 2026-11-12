--!nocheck
-- (v1.6.0 dogfood) ctx.shop.ownsPass never yields for a loaded player: every products.passes
-- entry is fetched at join, so a capBonus / rateFactor / roll inside a transaction reads the
-- cached answer. A call that WOULD yield inside a tx errors loudly instead of discarding the tx
-- with "fn must not yield" (or parking a sim spec forever). Runs on the multi-server sim (real
-- Shop + Data, UserOwnsGamePassAsync takes 0.05 s there).
local F = require("packages/framework/test/sim/Fixtures.luau")

local function boot()
	local world = F.world({ config = { products = { passes = { Vip = 77, Slots = 78 } } } })
	world.passes[1] = { [77] = true }
	local server = F.server(world)
	return world, server
end

local function joinLoaded(world, server, userId)
	local p = server:join(userId)
	world:advanceUntil(function()
		return server:isLoaded(p)
	end, 30)
	return p
end

describe("ctx.shop.ownsPass (v1.6.0: non-yielding for a loaded player)", function()
	it("answers inside a transaction from the join-time fetch, for every products.passes entry", function()
		local world, server = boot()
		local owner = joinLoaded(world, server, 1)
		local other = joinLoaded(world, server, 2)
		local shop = server.runtime.shop
		local seen = {}
		local committed = server:update(owner, function()
			seen.vip = shop.ownsPass(owner, "Vip")
			seen.slots = shop.ownsPass(owner, "Slots")
		end)
		expect(committed).toBe(true)
		expect(seen.vip).toBe(true)
		expect(seen.slots).toBe(false)
		expect(server:update(other, function()
			seen.otherVip = shop.ownsPass(other, 77)
		end)).toBe(true)
		expect(seen.otherVip).toBe(false)
		expect(#world:errors()).toBe(0)
	end)

	it("a call that would yield inside a tx errors with the fix, and the tx is discarded", function()
		local world, server = boot()
		local p = joinLoaded(world, server, 1)
		local ok, err = pcall(function()
			server:update(p, function()
				server.runtime.shop.ownsPass(p, 99) -- a raw id: never fetched at join
			end)
		end)
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("ownsPass yields: call it outside a transaction")
		expect(tostring(err)).toContain("onPassOwned")
	end)

	it("outside a tx an unknown pass is still looked up (yielding, in a server thread) and cached", function()
		local world, server = boot()
		world.passes[1][99] = true
		local p = joinLoaded(world, server, 1)
		local h = server:spawn(server.runtime.shop.ownsPass, p, 99)
		world:advanceUntil(function()
			return h.done
		end, 10)
		expect(h.error).toBe(nil)
		expect(h.result).toBe(true)
		local inside
		server:update(p, function()
			inside = server.runtime.shop.ownsPass(p, 99)
		end)
		expect(inside).toBe(true)
	end)

	it(
		"a lookup that failed at join reads as not owned inside a tx (no error) until a retry works",
		function()
			local world, server = boot()
			local down = true
			local real = server.MarketplaceService.UserOwnsGamePassAsync
			server.MarketplaceService.UserOwnsGamePassAsync = function(self, userId, id)
				if down then
					error("sim: UserOwnsGamePassAsync down (injected)")
				end
				return real(self, userId, id)
			end
			local p = joinLoaded(world, server, 1)
			local shop = server.runtime.shop
			local inside
			expect(server:update(p, function()
				inside = shop.ownsPass(p, "Vip")
			end)).toBe(true)
			expect(inside).toBe(false)
			down = false
			local h = server:spawn(shop.ownsPass, p, "Vip")
			world:advanceUntil(function()
				return h.done
			end, 10)
			expect(h.result).toBe(true)
			server:update(p, function()
				inside = shop.ownsPass(p, "Vip")
			end)
			expect(inside).toBe(true)
		end
	)
end)
