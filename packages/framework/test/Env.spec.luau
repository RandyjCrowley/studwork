--!nocheck
--[[
	v1.7.0 environments (module-api.md §23.1, docs/framework/kits/environments.md): studio / test /
	live from the place and universe ids, an unlisted place is live, overlapping ids are a boot
	error, and the same resolver on both sides.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Framework = ReplicatedStorage:WaitForChild("Framework")
local StudWork = require(Framework)
local Env = require(Framework:WaitForChild("Env"))

local IDS = {
	test = { placeIds = { 222 }, universeIds = { 111 } },
	live = { placeIds = { 444 }, universeIds = { 333 } },
}

local function info(placeId, universeId, isStudio)
	return { isStudio = isStudio == true, placeId = placeId, universeId = universeId }
end

local function probe()
	return StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" })
end

local function boot(opts)
	local captured = {}
	local o = {
		modules = { probe() },
		servers = {
			Probe = {
				init = function(ctx)
					captured.ctx = ctx
				end,
			},
		},
	}
	for k, v in opts or {} do
		o[k] = v
	end
	local h, err = StudWork.test.boot(o)
	return h, err, captured.ctx
end

local function hasWarning(h, text)
	for _, w in h:warnings() do
		if string.find(w, text, 1, true) then
			return true
		end
	end
	return false
end

describe("Env.resolve", function()
	it("is studio in Studio, whatever the ids say", function()
		expect(Env.resolve(IDS, info(444, 333, true))).toBe("studio")
		expect(Env.resolve(IDS, info(222, 111, true))).toBe("studio")
		expect(Env.resolve(nil, info(0, 0, true))).toBe("studio")
	end)

	it("is test for a listed test place or any place of a listed test universe", function()
		expect(Env.resolve(IDS, info(222, 111))).toBe("test")
		expect(Env.resolve(IDS, info(999, 111))).toBe("test") -- a sub-place of the test experience
		expect(Env.resolve({ test = { placeIds = { 222 } } }, info(222, 333))).toBe("test")
	end)

	it("a live universe listed under test never makes a live server test (M4)", function()
		-- hand-written: the live universe under test, no live list: every server would be test
		local shared = { test = { universeIds = { 333 } } }
		expect(Env.resolve(shared, info(444, 333))).toBe("live")
		expect(Env.resolve(shared, info(999, 333))).toBe("live")
		-- the live place listed by place id only, the universe under test
		local byPlace = { test = { universeIds = { 333 } }, live = { placeIds = { 444 } } }
		expect(Env.resolve(byPlace, info(444, 333))).toBe("live")
		expect(Env.resolve(byPlace, info(555, 333))).toBe("live") -- a live sub-place too
		-- a live place id beats a (trusted) test universe
		local both =
			{ test = { universeIds = { 111 } }, live = { placeIds = { 444 }, universeIds = { 333 } } }
		expect(Env.resolve(both, info(444, 111))).toBe("live")
		expect(Env.resolve(both, info(999, 111))).toBe("test")
		-- a test place id is explicit and still wins (a test place inside the live experience)
		expect(
			Env.resolve({ test = { placeIds = { 222 } }, live = { universeIds = { 333 } } }, info(222, 333))
		).toBe("test")
	end)

	it("is live for a live place and for any place nobody listed", function()
		expect(Env.resolve(IDS, info(444, 333))).toBe("live")
		expect(Env.resolve(IDS, info(5, 6))).toBe("live")
		expect(Env.resolve(nil, info(5, 6))).toBe("live")
		expect(Env.resolve({}, info(0, 0))).toBe("live")
	end)
end)

describe("Env.validate", function()
	it("accepts the generated shape and nothing configured", function()
		local errors, warnings = Env.validate(IDS, info(222, 111))
		expect(#errors).toBe(0)
		expect(#warnings).toBe(0)
		errors = Env.validate(nil)
		expect(#errors).toBe(0)
	end)

	it("an id under both test and live is an error (places and universes)", function()
		local errors = Env.validate({ test = { placeIds = { 1, 2 } }, live = { placeIds = { 2 } } })
		expect(#errors).toBe(1)
		expect(errors[1]).toContain("placeIds id 2 is listed under both test and live")
		errors = Env.validate({ test = { universeIds = { 7 } }, live = { universeIds = { 7 } } })
		expect(#errors).toBe(1)
		expect(errors[1]).toContain("universeIds id 7")
		-- a place id equal to a universe id is not an overlap (different kinds of id)
		errors = Env.validate({ test = { placeIds = { 7 } }, live = { universeIds = { 7 } } })
		expect(#errors).toBe(0)
	end)

	it("refuses bad shapes, placeholder ids and key typos", function()
		expect(#Env.validate("live")).toBe(1)
		expect(#Env.validate({ test = 5 })).toBe(1)
		expect(Env.validate({ test = { placeIds = { 0 } } })[1]).toContain("positive integer")
		expect(Env.validate({ test = { placeIds = { -3 } } })[1]).toContain("positive integer")
		expect(Env.validate({ test = { placeIds = { 1.5 } } })[1]).toContain("positive integer")
		expect(Env.validate({ test = { placeIds = { "222" } } })[1]).toContain("positive integer")
		expect(Env.validate({ test = { placeIds = 222 } })[1]).toContain("list of numbers")
		-- placeId (singular) would silently leave the test place out
		expect(Env.validate({ test = { placeId = { 222 } } })[1]).toContain("unknown key")
		local _, warnings = Env.validate({ staging = {} })
		expect(warnings[1]).toContain("unknown key")
	end)

	it("warns once that a test universe is ignored until the live universe is listed", function()
		local _, w = Env.validate({ test = { universeIds = { 333 } } }, info(444, 333))
		expect(#w).toBe(1)
		expect(w[1]).toContain("environments.test.universeIds is ignored")
		_, w =
			Env.validate({ test = { universeIds = { 111 } }, live = { placeIds = { 444 } } }, info(444, 333))
		expect(#w).toBe(1)
		_, w = Env.validate(IDS, info(222, 111))
		expect(#w).toBe(0)
		_, w = Env.validate({ test = { placeIds = { 222 } } }, info(222, 111))
		expect(#w).toBe(0)
	end)

	it("warns for an unlisted place only when environments.live is set, never in Studio", function()
		local _, w = Env.validate(IDS, info(5, 6))
		expect(#w).toBe(1)
		expect(w[1]).toContain("place 5 isn't in environments; treating it as live")
		_, w = Env.validate({ test = IDS.test }, info(5, 6))
		-- (no unlisted-place warning without a live list; the one warning is that the test universe
		-- is ignored until the live universe is listed, M4)
		expect(#w).toBe(1)
		expect(w[1]).toContain("environments.test.universeIds is ignored")
		_, w = Env.validate({ test = { placeIds = IDS.test.placeIds } }, info(5, 6))
		expect(#w).toBe(0)
		_, w = Env.validate(IDS, info(5, 6, true))
		expect(#w).toBe(0)
		_, w = Env.validate(IDS, info(5, 333)) -- another place of the live universe is listed
		expect(#w).toBe(0)
	end)
end)

describe("Env.testOptions (L1: StudWork.start's env options are for tests only)", function()
	it("passes them through with an injected platform and drops them on a live one", function()
		local o = { env = "test", isStudio = true, placeId = 1, universeId = 2 }
		local used, ignored = Env.testOptions(o, true)
		expect(used).toBe(o)
		expect(ignored).toBe(false)
		used, ignored = Env.testOptions(o, false)
		expect(used.env).toBe(nil)
		expect(used.isStudio).toBe(nil)
		expect(used.placeId).toBe(nil)
		expect(ignored).toBe(true)
		-- so a live server with the live place listed stays live whatever the game passed
		expect(Env.build(IDS, info(444, 333), used.env).name()).toBe("live")
		used, ignored = Env.testOptions({}, false)
		expect(ignored).toBe(false)
		used, ignored = Env.testOptions(nil, false)
		expect(ignored).toBe(false)
	end)
end)

describe("Env.build", function()
	it("is frozen and answers the ids; a forced name wins (tests only)", function()
		local e = Env.build(IDS, info(222, 111))
		expect(table.isfrozen(e)).toBe(true)
		expect(e.name()).toBe("test")
		expect(e.placeId()).toBe(222)
		expect(e.universeId()).toBe(111)
		expect(Env.build(IDS, info(222, 111), "live").name()).toBe("live")
	end)
end)

describe("environments at boot", function()
	it("a test universe id makes a sub-place test; ctx.env and StudWork.env agree", function()
		local h, _, ctx = boot({ placeId = 999, universeId = 111, environments = IDS })
		expect(h).never.toBeNil()
		expect(ctx.env.name()).toBe("test")
		expect(StudWork.env.name()).toBe("test")
		expect(ctx.env.universeId()).toBe(111)
		local p = h:addPlayer({ userId = 1 })
		expect(h:state(p).framework.env).toBe("test")
	end)

	it("a live universe under test (no live list) boots as live, so testOnly flags stay off", function()
		local h, _, ctx = boot({
			placeId = 444,
			universeId = 333,
			environments = { test = { universeIds = { 333 } } },
			flags = { beta = { default = false, test = true, testOnly = true } },
		})
		expect(h).never.toBeNil()
		expect(ctx.env.name()).toBe("live")
		expect(ctx.flags.isOn("beta")).toBe(false)
		expect(hasWarning(h, "environments.test.universeIds is ignored")).toBe(true)
	end)

	it("an unknown place is live, with one boot warning", function()
		local h, _, ctx = boot({ placeId = 5, universeId = 6, environments = IDS })
		expect(ctx.env.name()).toBe("live")
		expect(hasWarning(h, "place 5 isn't in environments; treating it as live")).toBe(true)
	end)

	it("overlapping ids are a boot error, with the other config errors", function()
		local h, err = boot({
			environments = { test = { universeIds = { 333 } }, live = { universeIds = { 333 } } },
			flags = { bad = { default = "yes" } },
		})
		expect(h).toBeNil()
		expect(err).toContain("universeIds id 333 is listed under both test and live")
		expect(err).toContain("flags.bad.default must be a boolean")
	end)

	it("Studio wins over a listed live place", function()
		local _, _, ctx = boot({ isStudio = true, placeId = 444, universeId = 333, environments = IDS })
		expect(ctx.env.name()).toBe("studio")
	end)
end)
