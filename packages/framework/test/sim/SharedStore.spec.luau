--[[
	ctx.data.shared (framework shared store, core-v1.3.0 Phase 2) in the multi-server sim: the
	runtime's SharedStore on the World's mock DataStore, so every sim server shares one store.
	Atomicity under concurrent updates from 2 servers, per-module namespacing, retry / failure,
	delete.
]]

local F = require(script.Parent.Fixtures)

local STORE = "StudWorkShared_" .. F.GAME_ID

local function shared(server, moduleName: string): any
	return server.runtime.shared.forModule(moduleName)
end

local function run(world, server, fn, ...): any
	local h = server:spawn(fn, ...)
	assert(
		world:advanceUntil(function()
			return h.done
		end, 120, 0.25),
		"call finished"
	)
	return h
end

describe("framework shared store (ctx.data.shared)", function()
	it("concurrent updates from 2 servers are atomic: no increment is lost", function()
		local world = F.world()
		world.latency = 0.2 -- every call waits, so the 2 servers' calls interleave
		world.ackLatency = 0.1
		local a, b = F.server(world), F.server(world)
		local handles = {}
		for i = 1, 50 do
			for _, s in { a, b } do
				table.insert(
					handles,
					s:spawn(shared(s, "Counter").update, "hits", function(old)
						return (old or 0) + 1
					end)
				)
			end
			if i % 10 == 0 then
				world:advance(0.05)
			end
		end
		assert(
			world:advanceUntil(function()
				for _, h in handles do
					if not h.done then
						return false
					end
				end
				return true
			end, 600, 0.05),
			"all done"
		)
		for _, h in handles do
			expect(h.error).toBeNil()
			expect(h.result).toBe(true)
		end
		expect(world:peek(STORE, "Counter/hits")).toBe(100)
		-- both servers wrote
		local writers = {}
		for _, entry in world.log do
			if entry.store == STORE then
				writers[entry.writer] = true
			end
		end
		expect(writers[a.jobId]).toBe(true)
		expect(writers[b.jobId]).toBe(true)
		-- every update returned the value it committed
		local h = run(world, b, shared(b, "Counter").update, "hits", function(old)
			return old + 1
		end)
		expect(h.result).toBe(true)
		expect(world:peek(STORE, "Counter/hits")).toBe(101)
		expect(#world:errors()).toBe(0)
	end)

	it("keys are namespaced by module: module A never sees module B's key", function()
		local world = F.world()
		local a = F.server(world)
		run(world, a, shared(a, "Alpha").update, "k", function()
			return "alpha's"
		end)
		local seen = "unset"
		run(world, a, shared(a, "Beta").update, "k", function(old)
			seen = old
			return "beta's"
		end)
		expect(seen).toBeNil()
		expect(world:peek(STORE, "Alpha/k")).toBe("alpha's")
		expect(world:peek(STORE, "Beta/k")).toBe("beta's")
		-- a key can't climb out of its namespace: "../" is just part of Beta's key
		run(world, a, shared(a, "Beta").update, "../Alpha/k", function(old)
			seen = old
			return "x"
		end)
		expect(seen).toBeNil()
		expect(world:peek(STORE, "Alpha/k")).toBe("alpha's")
		-- the ctx a module gets is bound to its own name (Mail's ctx.data.shared -> "Mail/...")
		expect(a.runtime.shared.forModule("Mail")).never.toBe(nil)
	end)

	it("retries a failing DataStore call, then reports a clear failure", function()
		local world = F.world()
		local a = F.server(world)
		local function onShared(_op, store)
			return store == STORE
		end
		world:failNext(2, onShared) -- 2 failures, the 3rd try commits
		local h = run(world, a, shared(a, "Retry").update, "n", function(old)
			return (old or 0) + 1
		end)
		expect(h.result).toBe(true)
		expect(world:peek(STORE, "Retry/n")).toBe(1)

		world:failNext(10, onShared) -- more failures than tries
		local before = #a.warnings
		local packed
		local h2 = a:spawn(function()
			packed = table.pack(shared(a, "Retry").update("n", function(old)
				return old + 1
			end))
		end)
		assert(
			world:advanceUntil(function()
				return h2.done
			end, 120, 0.25),
			"done"
		)
		expect(packed[1]).toBe(false)
		expect(packed[2]).toBeNil()
		expect(world:peek(STORE, "Retry/n")).toBe(1) -- nothing written
		local warned = false
		for i = before + 1, #a.warnings do
			if string.find(a.warnings[i], "Retry: update 'n' failed after", 1, true) then
				warned = true
			end
		end
		expect(warned).toBe(true)
		expect(#world:errors()).toBe(0)
	end)

	it("an error inside fn writes nothing and is not retried; nil deletes", function()
		local world = F.world()
		local a = F.server(world)
		run(world, a, shared(a, "Del").update, "k", function()
			return { v = 1 }
		end)
		local calls = 0
		local packed
		run(world, a, function()
			packed = table.pack(shared(a, "Del").update("k", function()
				calls += 1
				error("boom")
			end))
		end)
		expect(packed[1]).toBe(false)
		expect(calls).toBe(1)
		expect(world:peek(STORE, "Del/k").v).toBe(1)
		-- nil deletes (stored as a tombstone, read back as nil)
		run(world, a, function()
			packed = table.pack(shared(a, "Del").update("k", function()
				return nil
			end))
		end)
		expect(packed[1]).toBe(true)
		expect(packed[2]).toBeNil()
		local seen = "unset"
		run(world, a, shared(a, "Del").update, "k", function(old)
			seen = old
			return old
		end)
		expect(seen).toBeNil()
		-- bad keys are refused
		expect(function()
			shared(a, "Del").update("", function() end)
		end).toThrow("non-empty")
		expect(function()
			shared(a, "Del").update(string.rep("x", 60), function() end)
		end).toThrow("longer than")
	end)
end)
