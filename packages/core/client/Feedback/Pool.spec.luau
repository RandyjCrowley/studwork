local Pool = require(script.Parent.Pool)

describe("Feedback.Pool", function()
	it("never creates more than max and recycles the oldest", function()
		local created, resets = 0, 0
		local pool = Pool.new(function()
			created += 1
			return { id = created }
		end, function()
			resets += 1
		end, 3)
		local a = pool:acquire()
		pool:acquire()
		pool:acquire()
		local d = pool:acquire()
		expect(created).toBe(3)
		expect(pool:total()).toBe(3)
		expect(d == a).toBe(true) -- oldest recycled
		expect(resets).toBe(1)
		expect(pool:activeCount()).toBe(3)
		for _ = 1, 100 do
			pool:acquire()
		end
		expect(created).toBe(3)
	end)
	it("reuses released items", function()
		local created = 0
		local pool = Pool.new(function()
			created += 1
			return {}
		end, function() end, 5)
		local a = pool:acquire()
		pool:release(a)
		expect(pool:activeCount()).toBe(0)
		local b = pool:acquire()
		expect(b == a).toBe(true)
		expect(created).toBe(1)
		pool:release({}) -- unknown item ignored
		expect(pool:activeCount()).toBe(1)
	end)
end)
