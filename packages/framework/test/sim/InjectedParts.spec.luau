--[[
	A test's own server part for a kit module (the sim's opts.serverParts, e.g. a test double)
	boots next to the real kit modules and is reached through the normal surfaces
	(server:use / the runtime's txApis / extensions).
	core-v1.3.0 Phase 2: was Adapters.spec.luau (the v1.2 adapter hook); the adapter-only
	assertions went with the adapters ((internal build report, not public) lists them).
]]

local F = require(script.Parent.Fixtures)

local function fakeOffline(calls: { any })
	return {
		api = {
			onReturn = function(fn)
				table.insert(calls, "onReturn")
				return { Connected = true, fn = fn }
			end,
		},
		txApi = {
			ping = function(_tx)
				return "pong"
			end,
		},
		extensions = {},
	}
end

describe("a test-injected server part next to the real kit modules", function()
	it("boots, is reached through server:use, and the real siblings still work", function()
		local world = F.world()
		local calls = {}
		local server = F.server(world, { serverParts = { Offline = fakeOffline(calls) } })
		expect(server.runtime.state).toBe("running")
		local connection = server:use("Offline").onReturn(function() end)
		expect(connection.Connected).toBe(true)
		expect(calls).toEqual({ "onReturn" })
		-- the real siblings still boot and work
		local p = server:join(401)
		world:advanceUntil(function()
			return server:isLoaded(p)
		end, 30)
		expect(server:use("Economy").grant(p, 5, "test")).toBe(true)
		expect(#world:errors()).toBe(0)
	end)

	it("its api / txApi / extensions are the framework's surfaces of that module", function()
		local world = F.world()
		local calls = {}
		local server = F.server(world, { serverParts = { Offline = fakeOffline(calls) } })
		expect(server.runtime.state).toBe("running")
		local rt = server.runtime
		local ref = server:ref("Offline")
		local seen = {
			name = ref.name,
			hasRt = rt ~= nil and rt.data ~= nil,
			api = type(rt.apis[ref].onReturn),
			txApi = type(rt.txApis[ref].ping),
			extensions = type(rt.exts[ref]),
		}
		expect(seen).toEqual({
			name = "Offline",
			hasRt = true,
			api = "function",
			txApi = "function",
			extensions = "table",
		})
		local p = server:join(402)
		world:advanceUntil(function()
			return server:isLoaded(p)
		end, 30)
		local pong
		rt.data.runTx(p, function(tx)
			pong = rt.txApis[ref].ping(tx)
		end)
		expect(pong).toBe("pong")
		local connection = server:use("Offline").onReturn(function() end)
		expect(connection.Connected).toBe(true)
		expect(calls).toEqual({ "onReturn" })
		expect(#world:errors()).toBe(0)
	end)
end)
