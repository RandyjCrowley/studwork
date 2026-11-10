local LuckRule = require(script.Parent.LuckRule)

local function sent(luck: number, disclosed: boolean?): any
	return { tableId = "T", luck = luck, luckDisclosed = if disclosed == nil then true else disclosed }
end

describe("LuckRule.check (hard rule 11)", function()
	it("free rolls may use any luck", function()
		expect(LuckRule.check({ paid = false, luck = 3, luckDisclosed = false, sent = nil })).toBe(true)
	end)

	it("paid rolls with luck 1 always pass", function()
		expect(LuckRule.check({ paid = true, luck = 1, luckDisclosed = false, sent = nil })).toBe(true)
	end)

	it("paid + luck on a table without luckDisclosed fails", function()
		local ok, reason = LuckRule.check({ paid = true, luck = 2, luckDisclosed = false, sent = sent(2) })
		expect(ok).toBe(false)
		expect(reason).toBe(LuckRule.NOT_DISCLOSED)
	end)

	it("paid + luck before the odds were sent fails", function()
		local ok, reason = LuckRule.check({ paid = true, luck = 2, luckDisclosed = true, sent = nil })
		expect(ok).toBe(false)
		expect(reason).toBe(LuckRule.NOT_SENT)
	end)

	it("sent odds with another luck (or not marked disclosed) fail", function()
		local ok, reason = LuckRule.check({ paid = true, luck = 2, luckDisclosed = true, sent = sent(1.5) })
		expect(ok).toBe(false)
		expect(reason).toBe(LuckRule.LUCK_MISMATCH)
		local ok2, reason2 =
			LuckRule.check({ paid = true, luck = 2, luckDisclosed = true, sent = sent(2, false) })
		expect(ok2).toBe(false)
		expect(reason2).toBe(LuckRule.LUCK_MISMATCH)
		local ok3 =
			LuckRule.check({ paid = true, luck = 2, luckDisclosed = true, sent = { luckDisclosed = true } })
		expect(ok3).toBe(false)
	end)

	it("paid + luck passes once exactly that luck was sent", function()
		local ok, reason = LuckRule.check({ paid = true, luck = 1.5, luckDisclosed = true, sent = sent(1.5) })
		expect(ok).toBe(true)
		expect(reason).toBeNil()
	end)

	it("not-disclosed wins over not-sent (documented order)", function()
		local _, reason = LuckRule.check({ paid = true, luck = 2, luckDisclosed = false, sent = nil })
		expect(reason).toBe(LuckRule.NOT_DISCLOSED)
	end)

	it("message names the table, the luck and the reason", function()
		local m = LuckRule.message("Egg", 1.5, LuckRule.NOT_SENT)
		expect(string.find(m, "'Egg'", 1, true) ~= nil).toBe(true)
		expect(string.find(m, "1.5", 1, true) ~= nil).toBe(true)
		expect(string.find(m, "not received", 1, true) ~= nil).toBe(true)
		expect(
			string.find(LuckRule.message("Egg", 2, LuckRule.NOT_DISCLOSED), "luckDisclosed", 1, true) ~= nil
		).toBe(true)
		expect(string.find(LuckRule.message("Egg", 2, LuckRule.LUCK_MISMATCH), "setLuck", 1, true) ~= nil).toBe(
			true
		)
	end)
end)
