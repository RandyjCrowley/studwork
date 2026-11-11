--[[
	Self-tests of the simulation harness itself (Scheduler, Signal, mock DataStore, messaging,
	server crash), so the scenario specs can trust it.
]]

local Scheduler = require(script.Parent.Scheduler)
local Signal = require(script.Parent.Signal)
local World = require(script.Parent.World)
local F = require(script.Parent.Fixtures)

local OWNER = { name = "owner" }

describe("Scheduler", function()
	it("task.wait really suspends and resumes on the virtual clock, in wake order", function()
		local s = Scheduler.new()
		local order = {}
		s:spawn(OWNER, function()
			s:wait(2)
			table.insert(order, "two")
		end)
		s:spawn(OWNER, function()
			s:wait(1)
			table.insert(order, "one")
		end)
		expect(#order).toBe(0)
		s:advance(1.5)
		expect(order[1]).toBe("one")
		expect(#order).toBe(1)
		s:advance(1)
		expect(order[2]).toBe("two")
	end)

	it("task.wait() resumes on the next frame, never in the same one", function()
		local s = Scheduler.new()
		local frames = 0
		s:spawn(OWNER, function()
			for _ = 1, 3 do
				s:wait()
				frames += 1
			end
		end)
		s:step()
		expect(frames).toBe(1)
		s:step()
		s:step()
		expect(frames).toBe(3)
	end)

	it("spawn runs at once until the first yield; defer runs at the end of the step", function()
		local s = Scheduler.new()
		local log = {}
		s:spawn(OWNER, function()
			table.insert(log, "spawned")
			s:defer(OWNER, function()
				table.insert(log, "deferred")
			end)
			s:wait(0)
			table.insert(log, "after wait")
		end)
		expect(log[1]).toBe("spawned")
		expect(#log).toBe(1)
		s:step()
		expect(log[2]).toBe("deferred")
		expect(log[3]).toBe("after wait")
	end)

	it("delay and cancel", function()
		local s = Scheduler.new()
		local hit = {}
		s:delay(OWNER, 1, function(x)
			table.insert(hit, x)
		end, "a")
		local t = s:delay(OWNER, 1, function(x)
			table.insert(hit, x)
		end, "b")
		s:cancel(t)
		s:advance(2)
		expect(#hit).toBe(1)
		expect(hit[1]).toBe("a")
	end)

	it(
		"a thread parked with raw coroutine.yield and resumed by another thread can still task.wait",
		function()
			-- ProfileStore's WaitInUpdateQueue does exactly this.
			local s = Scheduler.new()
			local parked
			local done = false
			s:spawn(OWNER, function()
				parked = coroutine.running()
				coroutine.yield()
				s:wait(1)
				done = true
			end)
			s:spawn(OWNER, function()
				s:wait(0.5)
				coroutine.resume(parked)
			end)
			s:advance(1)
			expect(done).toBe(false)
			s:advance(1)
			expect(done).toBe(true)
		end
	)

	it("kill(owner) stops its threads and hooks; errors are collected, not thrown", function()
		local s = Scheduler.new()
		local ticks, after = 0, false
		local dead = { name = "dead" }
		s:addHook(dead, function()
			ticks += 1
		end)
		s:spawn(dead, function()
			s:wait(1)
			after = true
		end)
		s:spawn(OWNER, function()
			error("boom")
		end)
		s:step()
		s:kill(dead)
		s:advance(2)
		expect(ticks).toBe(1)
		expect(after).toBe(false)
		expect(#s.errors).toBe(1)
		expect(s.errors[1].message).toContain("boom")
	end)

	it("os.time follows the clock", function()
		local s = Scheduler.new({ epoch = 1000 })
		expect(s:time()).toBe(1000)
		s:advance(2.5, 0.5)
		expect(s:time()).toBe(1002)
	end)
end)

describe("Signal", function()
	it("runs each handler in its own thread (a yielding handler does not block the next)", function()
		local s = Scheduler.new()
		local sig = Signal.new(s, OWNER)
		local log = {}
		sig:Connect(function(x)
			s:wait(1)
			table.insert(log, "slow " .. x)
		end)
		sig:Connect(function(x)
			table.insert(log, "fast " .. x)
		end)
		sig:Fire("a")
		expect(log[1]).toBe("fast a")
		s:advance(1)
		expect(log[2]).toBe("slow a")
		expect(sig:count()).toBe(1)
	end)
end)

describe("mock DataStore", function()
	local function store(world)
		local server = { jobId = "job-x", alive = true, name = "x" }
		return world:dataStoreService(server):GetDataStore("S"), server
	end

	it("UpdateAsync is an atomic read-modify-write with latency, deep copies and a write log", function()
		local world = World.new()
		world.latency = 1
		local ds, server = store(world)
		local result
		world.scheduler:spawn(server, function()
			result = ds:UpdateAsync("k", function(old)
				local v = old or { n = 0 }
				v.n += 1
				return v
			end)
		end)
		expect(world:peek("S", "k")).toBeNil()
		world:advance(1.5)
		expect(result.n).toBe(1)
		result.n = 50 -- callers get copies
		expect(world:peek("S", "k").n).toBe(1)
		expect(#world.log).toBe(1)
		expect(world.log[1].writer).toBe("job-x")
	end)

	it("returning nil from the transform cancels the write", function()
		local world = World.new()
		local ds, server = store(world)
		world.scheduler:spawn(server, function()
			ds:UpdateAsync("k", function()
				return nil
			end)
		end)
		world:advance(0.1)
		expect(world:peek("S", "k")).toBeNil()
		expect(#world.log).toBe(0)
	end)

	it("injected failures error after the latency; non-serializable values are rejected", function()
		local world = World.new()
		world:failNext(1)
		local ds, server = store(world)
		local results = {}
		world.scheduler:spawn(server, function()
			table.insert(results, (pcall(ds.UpdateAsync, ds, "k", function()
				return { a = 1 }
			end)))
			table.insert(results, (pcall(ds.UpdateAsync, ds, "k", function()
				return { a = 1 }
			end)))
			table.insert(results, (pcall(ds.UpdateAsync, ds, "k", function()
				return { f = function() end }
			end)))
		end)
		world:advance(0.1)
		expect(results[1]).toBe(false)
		expect(results[2]).toBe(true)
		expect(results[3]).toBe(false)
		expect(world:peek("S", "k").a).toBe(1)
	end)

	it("a crashed server's in-flight write never commits", function()
		local world = World.new()
		world.latency = 2
		local ds, server = store(world)
		world.scheduler:spawn(server, function()
			ds:UpdateAsync("k", function()
				return { a = 1 }
			end)
		end)
		world:advance(1)
		world.scheduler:kill(server)
		world:advance(5)
		expect(world:peek("S", "k")).toBeNil()
	end)
end)

describe("MessagingService bus", function()
	it("delivers to live subscribers of other servers, and can be switched off", function()
		local world = World.new()
		local a = { jobId = "a", alive = true, name = "a" }
		local b = { jobId = "b", alive = true, name = "b" }
		local got = {}
		world:messagingService(b):SubscribeAsync("t", function(msg)
			table.insert(got, msg.Data.x)
		end)
		local ms = world:messagingService(a)
		world.scheduler:spawn(a, function()
			ms:PublishAsync("t", { x = 1 })
			world.messagingEnabled = false
			ms:PublishAsync("t", { x = 2 })
		end)
		world:advance(1)
		expect(#got).toBe(1)
		expect(got[1]).toBe(1)
	end)
end)

describe("Fixtures.writerViolations", function()
	it("flags a Data change written by a server that did not hold the lock", function()
		local world = World.new()
		local key = F.key(1)
		local function value(coins, holder)
			return {
				Data = { coins = coins },
				MetaData = { ActiveSession = holder and { 1, holder, "s" } or nil },
			}
		end
		world.log = {
			{
				at = 1,
				store = F.STORE,
				key = key,
				writer = "A",
				before = value(0, "A"),
				after = value(5, "A"),
			},
			{
				at = 2,
				store = F.STORE,
				key = key,
				writer = "B",
				before = value(5, "A"),
				after = value(5, "B"),
			},
		}
		expect(#F.writerViolations(world, 1)).toBe(0) -- B only took the lock, Data unchanged
		table.insert(world.log, {
			at = 3,
			store = F.STORE,
			key = key,
			writer = "A",
			before = value(5, "B"),
			after = value(9, "B"),
		})
		local violations = F.writerViolations(world, 1)
		expect(#violations).toBe(1)
		expect(violations[1]).toContain("A changed Data while B held the lock")
	end)
end)
