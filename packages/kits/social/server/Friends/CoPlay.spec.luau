local CoPlay = require(script.Parent.CoPlay)

describe("Friends.CoPlay", function()
	it("invite when the referrer is a friend in the server", function()
		expect(CoPlay.kind(7, { 5, 7 }, false)).toBe("invite")
		expect(CoPlay.kind(7, { 5, 7 }, true)).toBe("invite")
	end)

	it("private server when not invited", function()
		expect(CoPlay.kind(nil, { 5 }, true)).toBe("private")
		expect(CoPlay.kind(9, { 5 }, true)).toBe("private") -- referrer not here
	end)

	it("server otherwise", function()
		expect(CoPlay.kind(nil, { 5 }, false)).toBe("server")
		expect(CoPlay.kind(0, { 5 }, false)).toBe("server")
	end)

	it("gained lists only new friend ids", function()
		expect(CoPlay.gained({}, { [3] = true, [1] = true })).toEqual({ 1, 3 })
		expect(CoPlay.gained({ [1] = true }, { [1] = true })).toEqual({})
		expect(CoPlay.gained({ [1] = true, [2] = true }, { [2] = true, [4] = true })).toEqual({ 4 })
	end)

	it("pairKey is order independent", function()
		expect(CoPlay.pairKey(5, 2)).toBe(CoPlay.pairKey(2, 5))
		expect(CoPlay.pairKey(2, 5)).toBe("2:5")
	end)
end)
