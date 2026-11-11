--[[
	Leave -> rejoin with saved data intact (known-issues "Not verified live": leave/rejoin).
	Real framework Data + real ProfileStore 1.0.3 on the mock DataStore; see sim/README.md.
]]

local F = require(script.Parent.Fixtures)

local function loaded(world, server, player, seconds: number?): boolean
	return world:advanceUntil(function()
		return server:isLoaded(player)
	end, seconds or 30)
end

local function released(world, userId: number, seconds: number?): boolean
	return world:advanceUntil(function()
		return F.lockHolder(world, userId) == nil
	end, seconds or 30)
end

-- Coins, one item and a game-table value: three different sections.
local function play(server, player)
	expect(server:use("Economy").grant(player, 120, "test")).toBe(true)
	local item = server:use("Inventory").add(player, "dust", { source = "drop" })
	expect(item).never.toBeNil()
	expect(server:update(player, function(d)
		d.sim.touches = 7 -- the fixture game module's own section (data.key = gameId)
	end)).toBe(true)
	return item
end

local CONFIG = { data = { default = { touches = 0 }, version = 1 } }

describe("leave -> rejoin", function()
	it("same server: everything saved on leave is loaded again (sessions = 2)", function()
		local world = F.world({ config = CONFIG })
		local a = F.server(world)
		local p = a:join(1)
		expect(loaded(world, a, p)).toBe(true)
		expect(a:section(p, "_framework").stats.sessions).toBe(1)
		local item = play(a, p)
		a:leave(p)
		expect(released(world, 1)).toBe(true)

		local stored = F.saved(world, 1)
		expect(stored.economy.currency.Coins).toBe(120)
		expect(stored.inventory.inventory[item.uid].itemId).toBe("dust")
		expect(stored.sim.touches).toBe(7)

		world:advance(90)
		local p2 = a:join(1)
		expect(loaded(world, a, p2)).toBe(true)
		local d = a:sections(p2)
		expect(d.economy.currency.Coins).toBe(120)
		expect(d.inventory.inventory[item.uid].itemId).toBe("dust")
		expect(d.sim.touches).toBe(7)
		expect(d._framework.stats.sessions).toBe(2)
		expect(#world:errors()).toBe(0)
		expect(#F.writerViolations(world, 1)).toBe(0)
	end)

	it("different server, joining while the old server's release save is still in flight", function()
		local world = F.world({ config = CONFIG })
		world.latency = 1.5 -- every DataStore call takes 1.5 s
		local a = F.server(world)
		local b = F.server(world)
		local p = a:join(2)
		expect(loaded(world, a, p)).toBe(true)
		local item = play(a, p)

		-- A's first release write hits a DataStore error (ProfileStore retries it), so B's first
		-- read certainly still sees A's lock.
		world:failNext(1, function(_op, _store, _key, writer)
			return writer == a.jobId
		end)
		a:leave(p)
		local q = b:join(2)
		expect(loaded(world, b, q, 90)).toBe(true)
		local sawLock = false
		for _, w in world.log do
			local session = w.before and w.before.MetaData and w.before.MetaData.ActiveSession
			if w.writer == b.jobId and session and session[2] == a.jobId then
				sawLock = true
			end
		end
		expect(sawLock).toBe(true)
		local d = b:sections(q)
		expect(d.economy.currency.Coins).toBe(120)
		expect(d.inventory.inventory[item.uid].itemId).toBe("dust")
		expect(d.sim.touches).toBe(7)
		expect(d._framework.stats.sessions).toBe(2)
		-- B never loaded default data, not even transiently.
		for _, args in b:heard("framework.PlayerLoaded").history do
			expect(args[2].economy.currency.Coins).toBe(120)
		end
		expect(F.lockHolder(world, 2)).toBe(b.jobId)
		expect(#world:errors()).toBe(0)
		expect(#F.writerViolations(world, 2)).toBe(0)
	end)

	it("rejoin elsewhere before the old server noticed the leave: old server releases and kicks", function()
		local world = F.world({ config = CONFIG })
		local a = F.server(world)
		local b = F.server(world)
		local p = a:join(3)
		expect(loaded(world, a, p)).toBe(true)
		play(a, p)
		world:advance(5)
		-- an unsaved change right before the player shows up in server B
		a:use("Economy").grant(p, 5, "test")

		local q = b:join(3)
		expect(loaded(world, b, q, 90)).toBe(true)
		expect(b:section(q, "economy").currency.Coins).toBe(125)
		expect(p.Parent).toBeNil() -- A kicked its copy of the player
		local kicked = false
		for _, k in a.kicks do
			if k.userId == 3 and string.find(k.message, "another server", 1, true) then
				kicked = true
			end
		end
		expect(kicked).toBe(true)
		expect(F.lockHolder(world, 3)).toBe(b.jobId)
		expect(#F.writerViolations(world, 3)).toBe(0)
		expect(#world:errors()).toBe(0)
	end)

	it("lastSeen is stamped on leave and survives the round trip", function()
		local world = F.world({ config = CONFIG })
		local a = F.server(world)
		local p = a:join(4)
		expect(loaded(world, a, p)).toBe(true)
		world:advance(10)
		local leftAt = world:now()
		a:leave(p)
		expect(released(world, 4)).toBe(true)
		local stored = F.section(world, 4, "_framework")
		expect(stored.lastSeen).toBeGreaterThanOrEqual(leftAt)
		expect(stored.lastSeen).toBeLessThanOrEqual(leftAt + 1)
	end)
end)
