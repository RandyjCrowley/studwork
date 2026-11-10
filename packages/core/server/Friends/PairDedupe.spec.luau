local PairDedupe = require(script.Parent.PairDedupe)

local function resume(thread, ok, value)
	coroutine.resume(thread, ok, value)
end

describe("Friends.PairDedupe", function()
	it("shares one in-flight call between concurrent callers", function()
		local d = PairDedupe.new(resume)
		local gate: thread? = nil
		local results = {}
		local function call()
			gate = coroutine.running()
			coroutine.yield() -- the web call is in flight
			return true
		end
		local a = coroutine.create(function()
			local ok, v = d:get("1:2", call)
			table.insert(results, { "a", ok, v })
		end)
		local b = coroutine.create(function()
			local ok, v = d:get("1:2", call)
			table.insert(results, { "b", ok, v })
		end)
		coroutine.resume(a)
		coroutine.resume(b)
		expect(d.calls).toBe(1)
		expect(#results).toBe(0)
		coroutine.resume(gate :: thread)
		expect(#results).toBe(2)
		expect(results[1][2]).toBe(true)
		expect(results[1][3]).toBe(true)
		expect(results[2][3]).toBe(true)
		-- now cached: no further call
		local ok, v = d:get("1:2", function()
			error("should not be called")
		end)
		expect(ok).toBe(true)
		expect(v).toBe(true)
		expect(d.calls).toBe(1)
	end)

	it("does not cache failures and shares the failure with waiters", function()
		local d = PairDedupe.new(resume)
		local gate: thread? = nil
		local waiterOk: boolean? = nil
		local first = coroutine.create(function()
			d:get("1:2", function()
				gate = coroutine.running()
				coroutine.yield()
				error("http 500")
			end)
		end)
		coroutine.resume(first)
		local waiter = coroutine.create(function()
			local ok = d:get("1:2", function()
				return true
			end)
			waiterOk = ok
		end)
		coroutine.resume(waiter)
		coroutine.resume(gate :: thread)
		expect(waiterOk).toBe(false)
		expect(d.cache["1:2"]).toBe(nil)
		local ok, v = d:get("1:2", function()
			return false
		end)
		expect(ok).toBe(true)
		expect(v).toBe(false)
		expect(d.calls).toBe(2)
	end)

	it("respects keep() and forgetUser()", function()
		local keep = false
		local d = PairDedupe.new(resume, function()
			return keep
		end)
		d:get("1:2", function()
			return true
		end)
		expect(d.cache["1:2"]).toBe(nil)
		keep = true
		d:get("1:2", function()
			return true
		end)
		d:get("2:3", function()
			return true
		end)
		d:get("3:4", function()
			return true
		end)
		d:forgetUser(2)
		expect(d.cache["1:2"]).toBe(nil)
		expect(d.cache["2:3"]).toBe(nil)
		expect(d.cache["3:4"]).toBe(true)
	end)
end)
