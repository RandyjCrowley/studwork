local RateLimit = require(script.Parent.RateLimit)

describe("RateLimit", function()
	it("allows a burst then blocks until tokens refill", function()
		local now = 0
		local limiter = RateLimit.new(function()
			return now
		end)
		local limit = { rate = 2, burst = 3 }
		expect(limiter:allow(1, "Ev", limit)).toBe(true)
		expect(limiter:allow(1, "Ev", limit)).toBe(true)
		expect(limiter:allow(1, "Ev", limit)).toBe(true)
		expect(limiter:allow(1, "Ev", limit)).toBe(false)
		now = 0.5 -- +1 token
		expect(limiter:allow(1, "Ev", limit)).toBe(true)
		expect(limiter:allow(1, "Ev", limit)).toBe(false)
	end)

	it("keeps players and events independent", function()
		local now = 0
		local limiter = RateLimit.new(function()
			return now
		end)
		local limit = { rate = 1, burst = 1 }
		expect(limiter:allow(1, "A", limit)).toBe(true)
		expect(limiter:allow(1, "A", limit)).toBe(false)
		expect(limiter:allow(1, "B", limit)).toBe(true)
		expect(limiter:allow(2, "A", limit)).toBe(true)
	end)

	it("treats a clock going backwards as no refill", function()
		local now = 10
		local limiter = RateLimit.new(function()
			return now
		end)
		local limit = { rate = 1, burst = 1 }
		expect(limiter:allow(1, "A", limit)).toBe(true)
		now = 5
		expect(limiter:allow(1, "A", limit)).toBe(false)
	end)

	it("forget() resets a player's buckets", function()
		local limiter = RateLimit.new(function()
			return 0
		end)
		local limit = { rate = 1, burst = 1 }
		expect(limiter:allow(1, "A", limit)).toBe(true)
		limiter:forget(1)
		expect(limiter:allow(1, "A", limit)).toBe(true)
	end)
end)
