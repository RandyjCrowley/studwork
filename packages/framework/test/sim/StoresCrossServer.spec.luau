--!nocheck
--[[
	v1.7.0 stores across sim servers (module-api.md §23.3-§23.5, §23.10): every sim server shares
	the World's ordered stores and sorted maps, so the census counts the sim's servers, one module
	filling its memory share is refused on every server while another still writes, many servers
	together hit the per-structure limit, `increment` is never retried, an experience-level throttle
	backs off the module (on that server), and world:failNext reaches these stores.
]]

local F = require(script.Parent.Fixtures)
local World = require(script.Parent.World)

local THROTTLE_429 = "502: API Services rejected request with error. HTTP 429 (Too Many Requests)"

local function run(world, server, fn, ...)
	local h = server:spawn(fn, ...)
	assert(
		world:advanceUntil(function()
			return h.done
		end, 60, 0.25),
		"call finished"
	)
	assert(h.error == nil, tostring(h.error))
	return table.unpack(h.results, 1, h.results.n)
end

local function map(server, moduleName, name)
	return server.runtime.sortedMapStore.forModule(moduleName)(name)
end

local function board(server, moduleName, name)
	return server.runtime.orderedStore.forModule(moduleName)(name)
end

describe("census across sim servers", function()
	it("counts every running server and its players; a crashed server drops out", function()
		local world = F.world()
		local a, b, c = F.server(world), F.server(world), F.server(world)
		a:join(1)
		b:join(2)
		b:join(3)
		c:join(4)
		c:join(5)
		c:join(6)
		world:advance(125)
		for _, s in { a, b, c } do
			local reading = s.runtime.census.get()
			expect(reading.servers).toBe(3)
			expect(reading.players).toBe(6)
			expect(reading.peakPlayers).toBe(6)
		end
		c:crash()
		world:advance(125)
		local reading = a.runtime.census.get()
		expect(reading.servers).toBe(2)
		expect(reading.players).toBe(3)
		expect(reading.peakPlayers).toBe(6) -- the day's peak stays
		expect(world:errors()).toEqual({})
	end)
end)

describe("memory shares across sim servers", function()
	it("one module filling its share is refused on every server; another module still writes", function()
		local world = F.world()
		local a, b = F.server(world), F.server(world)
		local value = string.rep("x", 3000) -- 3036 bytes an item; a module's share is 16 KB: 5 items
		local okA = 0
		for i = 1, 3 do
			if run(world, a, map(a, "Fill", "m").set, "a" .. i, value, 3600) then
				okA += 1
			end
		end
		expect(okA).toBe(3)
		world:advance(185) -- a reports its charges; b reads them back (at most three cycles)
		expect(b.runtime.storeBudget.moduleBytes("Fill")).toBe(3 * 3036)
		local okB, refused = 0, nil
		for i = 1, 4 do
			local ok, reason = run(world, b, map(b, "Fill", "m").set, "b" .. i, value, 3600)
			if ok then
				okB += 1
			else
				refused = reason
			end
		end
		expect(okB).toBe(2)
		expect(refused).toBe("memory_budget")
		-- the other module has its own share, on both servers
		expect(run(world, a, map(a, "Other", "m").set, "k", value, 3600)).toBe(true)
		expect(run(world, b, map(b, "Other", "m").set, "k", value, 3600)).toBe(true)
		-- a remove gives the share back, experience-wide, once reported
		expect(run(world, b, map(b, "Fill", "m").remove, "b1")).toBe(true)
		world:advance(185)
		expect(a.runtime.storeBudget.moduleBytes("Fill")).toBe(4 * 3036)
		expect(run(world, a, map(a, "Fill", "m").set, "a9", value, 3600)).toBe(true)
		expect(#world.memoryStores.sortedMap("SW/Fill/m").entries()).toBe(5)
	end)
end)

describe("Roblox's limits across sim servers", function()
	it("many servers together hit the per-structure limit; each is under its own unit cap", function()
		local world =
			World.new({ memoryStores = { sortedMap = { structureLimit = 50, partitionLimit = 1000 } } })
		world.config = F.config()
		local servers = {}
		for s = 1, 5 do
			local server = F.server(world)
			server:join(s) -- one player each: a 40-unit cap, room for the retries
			table.insert(servers, server)
		end
		local handles = {}
		for s, server in servers do
			for i = 1, 12 do
				table.insert(handles, server:spawn(map(server, "Hot", "m").set, s .. "/" .. i, i, 600))
			end
		end
		assert(world:advanceUntil(function()
			for _, h in handles do
				if not h.done then
					return false
				end
			end
			return true
		end, 60, 0.25))
		local ok, throttled = 0, 0
		for _, h in handles do
			if h.results[1] then
				ok += 1
			elseif h.results[2] == "throttled" then
				throttled += 1
			end
		end
		expect(ok).toBe(50)
		expect(throttled).toBe(10)
		for _, server in servers do
			expect(server.runtime.storeBudget.unitsUsed() <= 40).toBe(true)
		end
	end)

	it("world:failNext with a store match reaches a sorted map; a rule without a match doesn't", function()
		local world = F.world()
		local a = F.server(world)
		world:failNext(3, function(_op, store)
			return store == "SW/Probe/m"
		end)
		local ok, reason = run(world, a, map(a, "Probe", "m").set, "k", 1, 60)
		expect(ok).toBe(false)
		expect(reason).toBe("failed")
		world:failNext(1)
		expect(run(world, a, map(a, "Probe", "m").set, "k", 1, 60)).toBe(true)
	end)
end)

describe("ordered stores across sim servers", function()
	local STORE = "ordered:SW/Probe/o"
	local function writes(world)
		local n = 0
		for _, entry in world.log do
			if entry.store == STORE then
				n += 1
			end
		end
		return n
	end

	it("increment is never retried; set is retried with backoff on the World's clock", function()
		local world = F.world()
		local a, b = F.server(world), F.server(world)
		world:failNext(1, function(_op, store)
			return store == STORE
		end)
		local ok, reason = run(world, a, board(a, "Probe", "o").increment, "1", 5)
		expect(ok).toBe(false)
		expect(reason).toBe("failed")
		expect(writes(world)).toBe(0)
		expect(run(world, a, board(a, "Probe", "o").increment, "1", 5)).toBe(true)
		expect(writes(world)).toBe(1)
		world:failNext(2, function(_op, store)
			return store == STORE
		end)
		local start = world:now()
		expect(run(world, b, board(b, "Probe", "o").set, "2", 9)).toBe(true)
		expect(world:now() - start >= 3).toBe(true) -- waited 1 s, then 2 s
		local _, value = run(world, a, board(a, "Probe", "o").get, "2")
		expect(value).toBe(9)
		expect(world:peek(STORE, "1")).toBe(5)
	end)

	it("an experience-level throttle backs off every ordered store of the module on that server", function()
		local world = F.world()
		local a, b = F.server(world), F.server(world)
		world.memoryStores.ordered("SW/Probe/o").failNext(1, THROTTLE_429)
		local ok, reason = run(world, a, board(a, "Probe", "o").set, "1", 1)
		expect(ok).toBe(false)
		expect(reason).toBe("budget")
		expect(select(2, run(world, a, board(a, "Probe", "other").get, "1"))).toBe("budget")
		expect(run(world, a, board(a, "Else", "o").set, "1", 1)).toBe(true) -- another module
		expect(run(world, b, board(b, "Probe", "o").set, "1", 2)).toBe(true) -- another server
		world:advance(31)
		expect(run(world, a, board(a, "Probe", "o").set, "1", 3)).toBe(true)
	end)
end)
