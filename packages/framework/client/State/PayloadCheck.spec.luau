local PayloadCheck = require(script.Parent.PayloadCheck)

describe("State.PayloadCheck", function()
	it("accepts init and patch payloads for our key", function()
		local ok = PayloadCheck.check({
			{ type = "init", data = { ["42"] = { loaded = false } } },
			{ type = "patch", data = { ["42"] = { ratePerSec = 3 } } },
		}, "42")
		expect(ok).toBe(true)
	end)
	it("refuses another player's key", function()
		local ok, reason = PayloadCheck.check({ { type = "patch", data = { ["7"] = {} } } }, "42")
		expect(ok).toBe(false)
		expect(reason).toBe("foreign key")
	end)
	it("refuses malformed payloads", function()
		expect((PayloadCheck.check(nil, "1"))).toBe(false)
		expect((PayloadCheck.check({}, "1"))).toBe(false)
		expect((PayloadCheck.check({ { type = "nope", data = {} } }, "1"))).toBe(false)
		expect((PayloadCheck.check({ { type = "patch" } }, "1"))).toBe(false)
		expect((PayloadCheck.check({ { type = "init", data = { ["1"] = { loaded = "yes" } } } }, "1"))).toBe(
			false
		)
	end)
end)
