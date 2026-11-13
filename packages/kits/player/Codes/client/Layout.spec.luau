local Layout = require(script.Parent.Layout)
describe("code entry bounds", function()
	it("caps input bytes without splitting a Unicode character", function()
		local clipped = Layout.input(string.rep("é", 33))
		expect(#clipped).toBe(64)
		expect((utf8.len(clipped))).toBe(32)
		expect(Layout.input(string.rep("a", 63) .. "é")).toBe(string.rep("a", 63))
	end)
	it("keeps the overlay above a phone keyboard and preserves physical touch targets", function()
		expect(Layout.available(375, true, 175, 200)).toBe(175)
		expect(Layout.available(375, true, 0, 200)).toBe(175)
		expect(Layout.available(720, false, 0, 0)).toBe(720)
		local target = Layout.touch(44, 0.85, 0.98)
		expect(target * 0.85 * 0.8 * 0.98 >= 44).toBe(true)
	end)
	it("accepts only preset outcome keys, never arbitrary input text", function()
		for _, key in
			{
				"ok",
				"invalid",
				"expired",
				"not_yet",
				"already_used",
				"limit_reached",
				"not_eligible",
				"try_later",
			}
		do
			expect(Layout.result(key)).toBe(key)
		end
		expect(Layout.result("PRIVATE_PROMOTION")).toBeNil()
	end)
end)
