--[[
	core-v1.3.1 (R19): Plot's client actions `display` / `clearDisplay` are module actions (§9) on
	Plot's own net.blink (Display / ClearDisplay), replacing the framework's RequestDisplay /
	RequestClearDisplay handlers. Real Plot server part, real framework (_sandbox game, all eleven
	modules); driven like the wire would: runtime.action (left / not loaded / rate limit / pcall).
]]

local F = require(script.Parent.Fixtures)

local SANDBOX = "games/_sandbox/default.project.json"

local function refOf(server, name: string): any
	for _, ref in server.runtime.order do
		if ref.name == name then
			return ref
		end
	end
	error("no module " .. name)
end

local function sandbox(userId: number)
	local world = F.world()
	local server = F.gameServer(world, SANDBOX)
	local p = server:join(userId)
	assert(
		world:advanceUntil(function()
			return server:isLoaded(p)
		end, 30),
		"load"
	)
	return world, server, p
end

describe("Plot actions (R19: Plot's own net.blink)", function()
	it("declares display and clearDisplay with the v1.2 limits (8/s, burst 16)", function()
		local _, server = sandbox(401)
		expect(server.runtime.net.hasAction("Plot", "display")).toBe(true)
		expect(server.runtime.net.hasAction("Plot", "clearDisplay")).toBe(true)
	end)

	it("clearDisplay(uid) through the action removes the displayed item", function()
		local world, server, p = sandbox(403)
		local rt = server.runtime
		local Plot = refOf(server, "Plot")
		local item = rt.apis[refOf(server, "Inventory")].add(p, "twig", { source = "drop" })
		rt.data.runTx(p, function(tx)
			rt.data.section(tx, "plot").displayed.slot07 = item.uid
		end)
		local ok, result = rt.action(p, Plot, "clearDisplay", item.uid)
		expect(ok).toBe(true)
		expect(result).toBe(true)
		expect(rt.apis[Plot].displayed(p).slot07).toBeNil()
		expect(#world:errors()).toBe(0)
	end)

	it("bad argument types are rejected by the handler, never reaching Plot's api", function()
		local world, server, p = sandbox(404)
		local rt = server.runtime
		local Plot = refOf(server, "Plot")
		for _, args in { { 123 }, { "" }, { string.rep("x", 65) }, { "uid", 5 }, { {} } } do
			local ok, result = rt.action(p, Plot, "display", table.unpack(args))
			expect(ok).toBe(true)
			expect(result).toBe(false)
		end
		local ok, result = rt.action(p, Plot, "clearDisplay", 42)
		expect(ok).toBe(true)
		expect(result).toBe(false)
		-- no plot model in the sim: a valid uid reaches Plot.display, which answers "no plot"
		local ok2, result2 = rt.action(p, Plot, "display", "some-uid")
		expect(ok2).toBe(true)
		expect(result2).toBe(false)
		expect(#world:errors()).toBe(0)
	end)

	it("rate limit (the v1.2 numbers): burst 16, then limited; refills at 8/s", function()
		local world, server, p = sandbox(405)
		local rt = server.runtime
		local Plot = refOf(server, "Plot")
		for _, name in { "display", "clearDisplay" } do
			for _ = 1, 16 do
				expect((rt.action(p, Plot, name, "nope"))).toBe(true)
			end
			local ok, reason = rt.action(p, Plot, name, "nope")
			expect(ok).toBe(false)
			expect(reason).toBe("rate_limited")
		end
		world:advance(1)
		for _ = 1, 8 do
			expect((rt.action(p, Plot, "display", "nope"))).toBe(true)
		end
		expect((rt.action(p, Plot, "display", "nope"))).toBe(false)
	end)
end)
