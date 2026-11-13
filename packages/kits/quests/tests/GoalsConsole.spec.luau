--!nocheck
-- Goals console (docs/framework/kits/quests.md, Goals API "Console"): `goals state` is read-only;
-- `goals complete` and `goals reset` are Studio-only (refused with isStudio = false).
local G = require("packages/kits/quests/tests/GoalsHelpers.luau")
local Goals = G.Goals

local CHAIN = {
	{ id = "a", check = { call = true }, funnel = "StepA" },
	{ id = "b", check = { call = true }, funnel = "StepB" },
}

describe("Goals console", function()
	it("goals state reports the current goal", function()
		local h = G.boot({ chain = CHAIN, isStudio = false })
		h:addPlayer({ userId = 1 })
		local reply = h:console("goals", "state", "1")
		expect(string.find(reply, "a (1/2)", 1, true) ~= nil).toBe(true)
		expect(h:console("goals", "state", "99")).toBe("no loaded player")
	end)

	it("goals complete and goals reset are refused outside Studio", function()
		local h = G.boot({ chain = CHAIN, isStudio = false })
		local p = h:addPlayer({ userId = 2 })
		expect(h:console("goals", "complete", "a", "2")).toBe("goals complete is Studio-only")
		expect(h:console("goals", "reset", "2")).toBe("goals reset is Studio-only")
		h:tick(1)
		expect(h:use(Goals).current(p).id).toBe("a")
	end)

	it("in Studio: complete goes through Goals.complete; reset starts the chain over", function()
		local h = G.boot({ chain = CHAIN, isStudio = true })
		local p = h:addPlayer({ userId = 3 })
		expect(h:console("goals", "complete", "a", "3")).toBe("a: completed")
		expect(h:console("goals", "complete", "nope", "3")).toBe("unknown goal 'nope'")
		h:tick(1)
		expect(h:use(Goals).current(p).id).toBe("b")
		expect(h:console("goals", "complete", "a", "3")).toBe("a: done")
		expect(h:console("goals", "reset", "3")).toBe("goals reset")
		expect(h:use(Goals).current(p).id).toBe("a")
		h:removePlayer(p)
		expect(h:saved(p).goals.done).toEqual({})
		expect(G.count(G.funnels(h, p), "StepA")).toBe(1) -- the framework logs a step once per player
	end)
end)
