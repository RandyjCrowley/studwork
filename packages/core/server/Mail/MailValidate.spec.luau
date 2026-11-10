local MailValidate = require(script.Parent.MailValidate)

local function encode(v: any): string
	-- rough stand-in for JSONEncode: only length matters for the size check
	local parts = {}
	local function walk(x: any)
		if type(x) == "table" then
			for k, c in x do
				table.insert(parts, tostring(k))
				walk(c)
			end
		else
			table.insert(parts, tostring(x))
		end
	end
	walk(v)
	return table.concat(parts, ",")
end

describe("MailValidate", function()
	it("accepts a small valid message", function()
		expect(MailValidate.message(123, "gift", { itemId = "a", n = 2 }, encode)).toBe(true)
	end)

	it("rejects bad user ids and kinds", function()
		expect(MailValidate.message(0, "gift", {}, encode)).toBe(false)
		expect(MailValidate.message(1.5, "gift", {}, encode)).toBe(false)
		expect(MailValidate.message(0 / 0, "gift", {}, encode)).toBe(false)
		expect(MailValidate.message(1, "", {}, encode)).toBe(false)
		expect(MailValidate.message(1, "has space", {}, encode)).toBe(false)
		expect(MailValidate.message(1, string.rep("a", 33), {}, encode)).toBe(false)
	end)

	it("rejects non-JSON-safe or oversized payloads", function()
		expect(MailValidate.message(1, "k", "x" :: any, encode)).toBe(false)
		expect(MailValidate.message(1, "k", { n = 0 / 0 }, encode)).toBe(false)
		expect(MailValidate.message(1, "k", { f = print }, encode)).toBe(false)
		expect(MailValidate.message(1, "k", { a = { b = { c = { d = 1 } } } }, encode)).toBe(false)
		expect(MailValidate.message(1, "k", { s = string.rep("x", 2000) }, encode)).toBe(false)
	end)

	it("rejects payloads whose encoder errors", function()
		local ok, reason = MailValidate.message(1, "k", {}, function()
			error("nope")
		end)
		expect(ok).toBe(false)
		expect(reason).toContain("JSON")
	end)
end)
