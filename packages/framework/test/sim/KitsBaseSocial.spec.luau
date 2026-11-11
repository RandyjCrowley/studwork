--[[
	core-v1.3.0 Phase 1 agent C: the REAL Mail and Streak modules (social / engagement kits) in
	the multi-server sim, through the framework's normal surfaces (runtime apis / txApis / exts /
	console). Gifting, cross-server gifting and co-play are covered by the existing sim specs,
	which now run against the real modules too.
]]

local F = require(script.Parent.Fixtures)

local function loaded(world, server, player): boolean
	return world:advanceUntil(function()
		return server:isLoaded(player)
	end, 30)
end

local function refOf(server, name: string): any
	for _, ref in server.runtime.order do
		if ref.name == name then
			return ref
		end
	end
	error("no module " .. name)
end

local function api(server, name: string): any
	return server.runtime.apis[refOf(server, name)]
end
local function txApi(server, name: string): any
	return server.runtime.txApis[refOf(server, name)]
end
local function ext(server, name: string): any
	return server.runtime.exts[refOf(server, name)]
end

describe("Mail (real module): R6 live admin console for failed mail", function()
	it("lists dead letters and re-delivers them for ServerConfig.Mail.admins only", function()
		local world = F.world({ config = { config = { Mail = { mail = { maxAttempts = 1 } } } } })
		local server = F.server(world, { serverConfig = { Mail = { admins = { 401 } } } })
		local admin, sender, receiver = server:join(401), server:join(402), server:join(403)
		assert(
			loaded(world, server, admin) and loaded(world, server, sender) and loaded(world, server, receiver),
			"load"
		)
		local broken = true
		local got = {}
		ext(server, "Mail").registerKind("r6_test", function(_tx, player, payload)
			if broken then
				error("handler broke")
			end
			table.insert(got, { userId = player.UserId, n = payload.n })
			return true
		end)
		server.runtime.data.runTx(sender, function(tx)
			expect(txApi(server, "Mail").send(tx, 403, "r6_test", { n = 3 }, "r6-key-1")).toBe(true)
		end)
		world:advance(5)
		local rt = server.runtime

		-- a player who isn't an admin is refused; the admin sees the dead letter
		local okNo, refused = rt.runConsole(sender, "mail dead 403")
		expect(okNo).toBe(true)
		expect(refused).toBe("admins only")
		local ok, listing = rt.runConsole(admin, "mail dead 403")
		expect(ok).toBe(true)
		expect(string.find(listing, "dead r6-key-1 r6_test", 1, true) ~= nil).toBe(true)

		-- re-deliver once the handler works again
		broken = false
		local okNo2, refused2 = rt.runConsole(sender, "mail redeliver 403 r6-key-1")
		expect(okNo2).toBe(true)
		expect(refused2).toBe("admins only")
		expect(#got).toBe(0)
		local ok2, result = rt.runConsole(admin, "mail redeliver 403 r6-key-1")
		expect(ok2).toBe(true)
		expect(result).toBe("redelivered r6-key-1")
		expect(#got).toBe(1)
		expect(got[1].userId).toBe(403)
		expect(got[1].n).toBe(3)
		expect(#api(server, "Mail").pending(receiver)).toBe(0)
		-- and it is gone from the dead letters
		local _, after = rt.runConsole(nil, "mail dead 403")
		expect(string.find(after, "dead r6-key-1", 1, true)).toBeNil()
		expect(#world:errors()).toBe(0)
	end)

	it("the public api refuses reserved core_ kinds; registerKind / txApi may use them", function()
		local world = F.world()
		local server = F.server(world)
		local a = server:join(411)
		assert(loaded(world, server, a), "load")
		local Mail = api(server, "Mail")
		expect(Mail.send(412, "core_gift", { x = 1 })).toBe(false)
		expect(function()
			Mail.onReceive("core_thing", function()
				return true
			end)
		end).toThrow("reserved")
		expect(function()
			ext(server, "Mail").registerKind("core_c_test", function()
				return true
			end)
		end).never.toThrow()
	end)
end)

describe("Streak (real module): reward in the same tx through the optional Economy", function()
	it("day 1 grants the configured reward and fires StreakAdvanced / onDaily", function()
		local world = F.world({
			config = {
				modules = { "Items", "Inventory", "Economy", "Streak", "Mail" },
				config = { Streak = { streak = { graceHours = 6, rewards = { { day = 1, amount = 40 } } } } },
			},
		})
		local server = F.server(world)
		local p = server:join(421)
		assert(loaded(world, server, p), "load")
		world:advance(1)
		expect(api(server, "Streak").get(p).day).toBe(1)
		expect(api(server, "Economy").balance(p)).toBe(40)
		-- the section keeps the v1.2 field name (streak = { streak = {...} })
		expect(server:section(p, "streak").streak.day).toBe(1)
		expect(#world:errors()).toBe(0)
	end)
end)
