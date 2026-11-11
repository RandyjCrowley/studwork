--[[
	core-v1.3.0 Phase 1 prep: the per-kit adapter hook (packages/kits/compat/adapters/<Kit>.luau).
	A kit module whose ModuleServers.loadServer returns a REAL server part (here: a fake one,
	injected with the sim's opts.serverParts) is reached by the still-bridged v1.2 services and by
	Bridge.compatServices(rt) through its kit's adapter, adapter(name, rt, api, txApi, extensions).
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

describe("compat adapters for real kit modules", function()
	it("an empty adapter file (Phase 1 start): boot works, a v1.2 call errors naming the file", function()
		local world = F.world()
		local calls = {}
		local server = F.server(world, { serverParts = { Offline = fakeOffline(calls) } })
		expect(server.runtime.state).toBe("running")
		local Offline = server.services.Offline
		local ok, err = pcall(function()
			return Offline.onReturn
		end)
		expect(ok).toBe(false)
		expect(string.find(tostring(err), "adapters/Economy.luau", 1, true) ~= nil).toBe(true)
		expect(string.find(tostring(err), "real module", 1, true) ~= nil).toBe(true)
		-- the bridged siblings still boot and work
		local p = server:join(401)
		world:advanceUntil(function()
			return server:isLoaded(p)
		end, 30)
		expect(server.services.Economy.grant(p, 5, "test")).toBe(true)
		expect(#world:errors()).toBe(0)
	end)

	it("the kit adapter builds services.<Module> from the real module's surfaces", function()
		local world = F.world()
		local calls = {}
		local seen = {}
		local server = F.server(world, {
			serverParts = { Offline = fakeOffline(calls) },
			compatAdapters = {
				Economy = function(name, rt, api, txApi, extensions)
					table.insert(seen, {
						name = name,
						hasRt = rt ~= nil and rt.data ~= nil,
						api = type(api.onReturn),
						txApi = type(txApi.ping),
						extensions = type(extensions),
					})
					if name ~= "Offline" then
						return nil
					end
					return {
						onReturn = function(fn)
							return api.onReturn(fn)
						end,
					}
				end,
			},
		})
		expect(server.runtime.state).toBe("running")
		expect(#seen).toBe(1) -- only the real module goes through its adapter (once)
		expect(seen[1]).toEqual({
			name = "Offline",
			hasRt = true,
			api = "function",
			txApi = "function",
			extensions = "table",
		})
		local connection = server.services.Offline.onReturn(function() end)
		expect(connection.Connected).toBe(true)
		expect(calls).toEqual({ "onReturn" })
		-- the bridged Economy is untouched (no adapter call for a bridged module)
		expect(tostring(server.services.Offline)).toBe("AdaptedModule(Offline)")
		expect(#world:errors()).toBe(0)
	end)
end)
