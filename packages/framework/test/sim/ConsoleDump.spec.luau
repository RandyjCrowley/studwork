--[[
	Studio console `data dump [userId]` (framework command, core-v1.3.0 step 4b-IIb). The live
	Studio boot at 8e4175f printed "ok (no encoder)": the runtime asked platform.encode, which
	the live Platform did not provide. The dump now encodes through the platform (live:
	HttpService:JSONEncode; the sim's HttpService encodes with @lune/serde) and prints the
	sectioned save: one key per module section plus _framework.
]]

local F = require(script.Parent.Fixtures)

local serde = (getmetatable(getfenv(1)) :: any).__index.require("@lune/serde") -- as sim/Server.luau

local function joinLoaded(world, s, userId: number)
	local p = s:join(userId)
	assert(
		world:advanceUntil(function()
			return s:isLoaded(p)
		end, 30),
		"loaded"
	)
	return p
end

describe("console data dump", function()
	it("prints the player's sectioned save as JSON (Studio)", function()
		local world = F.world()
		local s = F.server(world, { isStudio = true })
		local p = joinLoaded(world, s, 91)
		s.services.Economy.grant(p, 42, "test")
		local text = s.console("data", "dump", "91")
		expect(text).never.toContain("no encoder")
		local ok, decoded = pcall(serde.decode, "json", text)
		expect(ok).toBe(true)
		expect(type(decoded)).toBe("table")
		expect(type(decoded._framework)).toBe("table")
		expect(type(decoded._framework.stats)).toBe("table")
		expect(decoded._framework.stats.sessions).toBe(1)
		-- the Economy kit's own section carries the grant
		expect(decoded.economy.currency.Coins).toBe(42)
		-- the default target (no userId) is the first player
		expect(s.console("data", "dump")).toBe(text)
		expect(#world:errors()).toBe(0)
	end)

	it("is Studio-only", function()
		local world = F.world()
		local s = F.server(world)
		joinLoaded(world, s, 92)
		expect(s.console("data", "dump", "92")).toBe("Studio-only")
	end)
end)
