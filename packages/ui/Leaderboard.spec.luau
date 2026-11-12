--!nocheck
--!nolint DeprecatedApi
--[[
	UI.Leaderboard: the pure helpers (LeaderboardFormat) and the component's rules read from its
	source (React isn't available under Lune): theme tokens only, names not auto-localized, every
	label through UI.text with keys that have English defaults, no English in the file.
]]
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local Format = require("packages/ui/LeaderboardFormat.luau")
local Strings = require("packages/ui/Strings.luau")
local Theme = require("packages/framework/shared/Theme.luau")

describe("LeaderboardFormat.value", function()
	it("number: whole numbers with thousands separators", function()
		expect(Format.value(0)).toBe("0")
		expect(Format.value(999)).toBe("999")
		expect(Format.value(1000)).toBe("1,000")
		expect(Format.value(1234567)).toBe("1,234,567")
		expect(Format.value(12345.9)).toBe("12,345")
		expect(Format.value(-1500)).toBe("-1,500")
		expect(Format.value(100000, "number")).toBe("100,000")
	end)

	it("number: NaN and infinities read 0", function()
		expect(Format.value(0 / 0)).toBe("0")
		expect(Format.value(math.huge)).toBe("0")
	end)

	it("time: m:ss, h:mm:ss from one hour, never negative", function()
		expect(Format.value(0, "time")).toBe("0:00")
		expect(Format.value(75, "time")).toBe("1:15")
		expect(Format.value(3599, "time")).toBe("59:59")
		expect(Format.value(3600, "time")).toBe("1:00:00")
		expect(Format.value(86399.7, "time")).toBe("23:59:59")
		expect(Format.value(-5, "time")).toBe("0:00")
	end)
end)

describe("LeaderboardFormat.plan", function()
	local rows = {
		{ rank = 1, userId = 10, name = "Ann", value = 5000 },
		{ rank = 2, userId = 20, name = "Bea", value = 40 },
	}

	it("lists the rows, marks the player's own and pins nothing when they are in the list", function()
		local plan = Format.plan({ rows = rows, selfUserId = 20, selfValue = 40, selfRank = 2 })
		expect(#plan.rows).toBe(2)
		expect(plan.rows[1].isSelf).toBe(false)
		expect(plan.rows[2].isSelf).toBe(true)
		expect(plan.rows[1].value).toBe("5,000")
		expect(plan.pinned).toBe(nil)
	end)

	it("pins the player's own row when they are outside the list: with a rank, or as Top N+", function()
		local ranked = Format.plan({ rows = rows, selfUserId = 99, selfValue = 7, selfRank = 3 })
		expect(ranked.pinned.rank).toBe(3)
		expect(ranked.pinned.outside).toBe(false)
		expect(ranked.pinned.value).toBe("7")
		local beyond = Format.plan({ rows = rows, selfUserId = 99, selfValue = 7 })
		expect(beyond.pinned.outside).toBe(true)
		expect(beyond.pinned.rank).toBe(nil)
	end)

	it("pins nothing without a self value or a self id, and handles no rows", function()
		expect(Format.plan({ rows = rows, selfUserId = 99 }).pinned).toBe(nil)
		expect(Format.plan({ rows = rows, selfValue = 5 }).pinned).toBe(nil)
		local empty = Format.plan({ rows = {} })
		expect(#empty.rows).toBe(0)
		expect(empty.pinned).toBe(nil)
		expect(#Format.plan({}).rows).toBe(0)
	end)

	it("formats the pinned value with the board's format", function()
		local plan = Format.plan({ rows = {}, selfUserId = 1, selfValue = 125, format = "time" })
		expect(plan.pinned.value).toBe("2:05")
	end)
end)

describe("UI.Leaderboard component", function()
	local source = fs.readFile("packages/ui/Leaderboard.luau")

	it("reads colours from theme tokens, including the base-theme leaderboardSelf", function()
		for _, token in { "leaderboardSelf", "surface", "surfaceAlt", "textMuted", "background" } do
			expect(string.find(source, `Theme.color("{token}")`, 1, true) ~= nil).toBe(true)
		end
		expect(Theme.DEFAULT.colors.leaderboardSelf).toBe("#FFD23F")
		expect(string.find(source, "Color3.", 1, true)).toBeNil()
		expect(string.find(source, "Font.new", 1, true)).toBeNil()
		expect(string.find(source, "Primitives.textSize(", 1, true)).toBeNil()
	end)

	it("renders names and numbers with AutoLocalize = false", function()
		expect(string.find(source, "AutoLocalize = false", 1, true) ~= nil).toBe(true)
	end)

	it("every label goes through UI.text, with keys that have English defaults", function()
		for _, key in
			{
				"ui.leaderboard.empty",
				"ui.leaderboard.you",
				"ui.leaderboard.outsideTop",
				"ui.leaderboard.rank",
			}
		do
			expect(string.find(source, key, 1, true) ~= nil).toBe(true)
			expect(Strings.DEFAULTS[key] ~= nil).toBe(true)
		end
		expect(Strings.DEFAULTS["ui.leaderboard.outsideTop"]).toContain("{count}")
		expect(Strings.DEFAULTS["ui.leaderboard.rank"]).toContain("{rank}")
	end)

	it("has no hard-coded English: every Text = is a variable or a call", function()
		for literal in string.gmatch(source, 'Text = "([^"]*)"') do
			expect(literal).toBe("") -- a literal label would be English
		end
		for literal in string.gmatch(source, "Text = '([^']*)'") do
			expect(literal).toBe("")
		end
	end)
end)
