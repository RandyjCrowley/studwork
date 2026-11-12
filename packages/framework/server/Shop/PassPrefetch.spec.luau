--!nocheck
-- (v1.6.1) GameConfig.shop.passPrefetchTimeout: how long a join waits for its gamepass lookups
-- (default 2 s, range 0-5). Purchase correctness never depends on it: a pass whose answer isn't
-- known yet is never guessed inside a transaction (a purchase is retried, anything else is
-- refused). Runs on the multi-server sim (real Shop + Data + Receipt, virtual clock).
local F = require("packages/framework/test/sim/Fixtures.luau")
local FrameworkServer = require(script.Parent.Parent)
local Shop = require(script.Parent)

-- opts.lookup: seconds UserOwnsGamePassAsync takes (default 0.05); opts.down() -> true = it errors
local function boot(opts)
	opts = opts or {}
	local overrides = { products = { passes = { Vip = 77 } } }
	if opts.shop then
		overrides.shop = opts.shop
	end
	local world = F.world({ config = overrides })
	world.passes[1] = { [77] = true }
	world.passes[2] = { [77] = true }
	local server = F.server(world)
	local real = server.MarketplaceService.UserOwnsGamePassAsync
	local lookups = { count = 0 }
	server.MarketplaceService.UserOwnsGamePassAsync = function(self, userId, id)
		lookups.count += 1
		if opts.lookup then
			world.scheduler:wait(opts.lookup)
		end
		if opts.down and opts.down() then
			error("sim: UserOwnsGamePassAsync down (injected)")
		end
		return real(self, userId, id)
	end
	return world, server, lookups
end

local function joinLoaded(world, server, userId)
	local p = server:join(userId)
	local t0 = world:now()
	world:advanceUntil(function()
		return server:isLoaded(p)
	end, 30)
	return p, world:now() - t0
end

local function timings(server, player)
	local out = {}
	for _, c in server.calls do
		if
			c.fn == "custom"
			and c.args[2] == "PlayerLoadTiming"
			and (player == nil or c.args[1] == player)
		then
			table.insert(out, { value = c.args[3], fields = c.args[4] })
		end
	end
	return out
end

local function deliver(world, server, receipt)
	local h = server:purchase(receipt)
	world:advanceUntil(function()
		return h.done
	end, 30)
	return h.result, h.error
end

-- a Coins100 handler that needs the pass; counts real grants (the handler body after ownsPass)
local function passProduct(server)
	local seen = { grants = 0, owns = {} }
	local gid = server.config.gameId
	server:onProduct("Coins100", function(tx)
		local owns = server.runtime.shop.ownsPass(tx.player, "Vip")
		seen.grants += 1
		table.insert(seen.owns, owns)
		local section = server.runtime.data.section(tx, gid)
		section.vipGrants = (section.vipGrants or 0) + 1
	end)
	return seen
end

local function recorded(server, player, purchaseId)
	local purchases = server.runtime.data.frameworkField(player, "purchases")
	return type(purchases) == "table" and purchases[purchaseId] ~= nil
end

describe("GameConfig.shop.passPrefetchTimeout (v1.6.1)", function()
	it(
		"a lookup slower than the timeout: the player loads after the timeout, not after the lookup",
		function()
			local world, server = boot({ lookup = 4 })
			local p, took = joinLoaded(world, server, 1)
			expect(server:isLoaded(p)).toBe(true)
			expect(took >= 1.9).toBe(true)
			expect(took < 3).toBe(true) -- 2 s timeout + the (fast) load, never the 4 s lookup
			local t = timings(server, p)
			expect(#t).toBe(1)
			expect(t[1].fields.timedOut).toBe("true")
			expect(t[1].fields.passesPending).toBe("1")
			-- the lookup keeps running in the background and fills the cache
			world:advance(3)
			local inside
			expect(server:update(p, function()
				inside = server.runtime.shop.ownsPass(p, "Vip")
			end)).toBe(true)
			expect(inside).toBe(true)
		end
	)

	it(
		"a purchase needing a still-pending pass is retried (nothing granted or recorded), then granted once",
		function()
			local world, server = boot({ lookup = 4 })
			local seen = passProduct(server)
			local p = joinLoaded(world, server, 1)
			local receipt = F.receipt(1, "pass-pending-1", 1001)
			local result = deliver(world, server, receipt)
			expect(result).toBe("NotProcessedYet")
			expect(seen.grants).toBe(0)
			expect(recorded(server, p, "pass-pending-1")).toBe(false)
			expect(server:section(p, server.config.gameId).vipGrants).toBe(nil)
			world:advance(4) -- the lookup answers
			expect(deliver(world, server, receipt)).toBe("PurchaseGranted")
			expect(seen.grants).toBe(1)
			expect(seen.owns[1]).toBe(true)
			expect(deliver(world, server, receipt)).toBe("PurchaseGranted") -- duplicate delivery
			expect(seen.grants).toBe(1)
			expect(server:section(p, server.config.gameId).vipGrants).toBe(1)
		end
	)

	it("a failed lookup is never read as 'not owned' by a purchase: retried until a lookup works", function()
		local down = true
		local world, server = boot({
			down = function()
				return down
			end,
		})
		local seen = passProduct(server)
		local p = joinLoaded(world, server, 1)
		local receipt = F.receipt(1, "pass-failed-1", 1001)
		for _ = 1, 3 do
			expect(deliver(world, server, receipt)).toBe("NotProcessedYet")
			world:advance(10)
		end
		expect(seen.grants).toBe(0)
		expect(recorded(server, p, "pass-failed-1")).toBe(false)
		down = false
		expect(deliver(world, server, receipt)).toBe("NotProcessedYet") -- starts a fresh lookup
		world:advance(5)
		expect(deliver(world, server, receipt)).toBe("PurchaseGranted")
		expect(seen.grants).toBe(1)
		expect(seen.owns[1]).toBe(true)
	end)

	it("the retry survives a handler that pcalls ownsPass (no guessed grant)", function()
		local world, server = boot({ lookup = 4 })
		local grants = 0
		server:onProduct("Coins100", function(tx)
			pcall(server.runtime.shop.ownsPass, tx.player, "Vip")
			grants += 1
		end)
		local p = joinLoaded(world, server, 1)
		expect(deliver(world, server, F.receipt(1, "pass-pcall-1", 1001))).toBe("NotProcessedYet")
		expect(recorded(server, p, "pass-pcall-1")).toBe(false)
		expect(grants).toBe(1) -- the body ran, but its tx was discarded
	end)

	it("a non-purchase transaction asking an unknown pass is refused (error), nothing changes", function()
		local world, server = boot({ lookup = 4 })
		local p = joinLoaded(world, server, 1)
		local gid = server.config.gameId
		local ok, err = pcall(function()
			server:update(p, function(s)
				s[gid].touched = true
				server.runtime.shop.ownsPass(p, "Vip")
			end)
		end)
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("ownsPass yields: call it outside a transaction")
		expect(tostring(err)).toContain("hasn't answered yet")
		expect(server:section(p, gid).touched).toBe(nil)
	end)

	it("0 = no wait at all; 5 is allowed", function()
		local world, server = boot({ lookup = 4, shop = { passPrefetchTimeout = 0 } })
		local p, took = joinLoaded(world, server, 1)
		expect(took < 0.5).toBe(true)
		expect(timings(server, p)[1].fields.passesPending).toBe("1")
		local world5, server5 = boot({ lookup = 4, shop = { passPrefetchTimeout = 5 } })
		local _, took5 = joinLoaded(world5, server5, 1)
		expect(took5 >= 3.9 and took5 < 5).toBe(true) -- waited for the 4 s answer
		expect(timings(server5)[1].fields.timedOut).toBe("false")
	end)

	it("validates at boot: default 2, 0..5 allowed, 6 / -1 / '2' refused naming the key and range", function()
		local function start(shop)
			local logs = {}
			local ok, rt = pcall(FrameworkServer.start, {
				gameId = "pass-test",
				modules = {},
				items = {},
				products = { passes = { Vip = 7 }, devProducts = {} },
				shop = shop,
			}, {}, {
				bindPlatform = false,
				logSink = function(level, msg)
					table.insert(logs, { level = level, msg = msg })
				end,
			})
			return ok, rt, logs
		end
		local ok, rt = start(nil)
		expect(ok).toBe(true)
		expect(rt.shop.passPrefetchTimeout()).toBe(2)
		expect(Shop.PASS_PREFETCH_SECONDS).toBe(5)
		for _, good in { 0, 2, 5, 0.5 } do
			local ok2, rt2, logs = start({ passPrefetchTimeout = good })
			expect(ok2).toBe(true)
			expect(rt2.shop.passPrefetchTimeout()).toBe(good)
			for _, l in logs do
				expect(l.msg).never.toContain("GameConfig.shop")
			end
		end
		for _, bad in { 6, -1, "2", 0 / 0 } do
			local ok3, err = start({ passPrefetchTimeout = bad })
			expect(ok3).toBe(false)
			expect(tostring(err)).toContain("GameConfig.shop.passPrefetchTimeout")
			expect(tostring(err)).toContain("from 0 to 5")
		end
		local ok4, err4 = start({ prefetch = 1 })
		expect(ok4).toBe(false)
		expect(tostring(err4)).toContain("GameConfig.shop.prefetch: unknown key")
	end)

	it("sends PlayerLoadTiming once per join with the timings", function()
		local world, server = boot()
		local a = joinLoaded(world, server, 1)
		local b = joinLoaded(world, server, 2)
		expect(#timings(server)).toBe(2)
		local t = timings(server, a)
		expect(#t).toBe(1)
		local f = t[1].fields
		for _, key in { "totalSeconds", "loadSeconds", "passSeconds", "passesPending", "timedOut" } do
			expect(type(f[key])).toBe("string")
		end
		expect(f.passesPending).toBe("0")
		expect(f.timedOut).toBe("false")
		expect(tonumber(f.passSeconds) > 0).toBe(true) -- the 0.05 s sim lookup
		expect(tonumber(f.totalSeconds) >= tonumber(f.passSeconds)).toBe(true)
		expect(type(t[1].value)).toBe("number")
		expect(#timings(server, b)).toBe(1)
	end)
end)
