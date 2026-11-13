--!nocheck
--[[
	Goals boot validation (Goals/shared/Validate.luau, kit page Goals "Validation at boot"): one bad
	chain per rule, every problem collected together, the forms that must pass, and the boot failing
	closed with all of them (and with Quests' real `def` behind quest checks).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Validate = require(Modules:WaitForChild("Goals"):WaitForChild("shared"):WaitForChild("Validate"))
local F = require("packages/kits/quests/tests/Fixtures.luau")

local ALL_ON = { Quests = true, Economy = true, Inventory = true, Rebirth = true, Streak = true }

local QUEST_DEFS = {
	story1 = { id = "story1", objectives = { {}, {} } },
}

local function env(overrides)
	local e = {
		enabled = ALL_ON,
		sources = { power = true },
		questDef = function(id)
			return QUEST_DEFS[id]
		end,
	}
	for k, v in overrides or {} do
		e[k] = v
	end
	return e
end

local function goal(id, check, extra)
	local g = { id = id, check = check }
	for k, v in extra or {} do
		g[k] = v
	end
	return g
end

local function has(errors, needle)
	for _, e in errors do
		if string.find(e, needle, 1, true) then
			return true
		end
	end
	return false
end

local function expectOne(errors, ...)
	expect(#errors .. " error(s): " .. table.concat(errors, " | ")).toBe("1 error(s): " .. (errors[1] or ""))
	for _, needle in { ... } do
		expect(needle .. "=" .. tostring(has(errors, needle))).toBe(needle .. "=true")
	end
end

describe("Goals validation: what passes", function()
	it("no chain, an empty chain, and the defaults are valid", function()
		expect(Validate.check(nil, {})).toEqual({})
		expect(Validate.check({}, {})).toEqual({})
		expect(Validate.check(F.Goals.config.defaults.chain, {})).toEqual({})
	end)

	it("every check and target form is valid", function()
		local chain = {
			goal("a", { quest = "story1" }),
			goal("b", { quest = "story1", on = "claimed" }, { target = { tag = "Guide" } }),
			goal("c", { quest = "story1", objective = 2 }, { target = { path = "Workspace.Map.Shop" } }),
			goal(
				"d",
				{ source = "currency", atLeast = 50 },
				{ target = { position = { 1, 2, 3 } }, fallback = { 0, 0, 0 } }
			),
			goal(
				"e",
				{ source = "itemOwned", atLeast = 1, params = { item = "gem" } },
				{ target = { picker = "nearestCrate" } }
			),
			goal("f", { source = "rebirths", atLeast = 1 }),
			goal("g", { source = "streakDay", atLeast = 2 }),
			goal("h", { source = "power", atLeast = 3 }),
			goal(
				"i",
				{ call = true },
				{ widget = "Economy.currency", funnel = "Step", text = "game.goal.i" }
			),
			goal("j", { ack = true }),
		}
		expect(Validate.check(chain, env())).toEqual({})
	end)
end)

describe("Goals validation: positions, two forms", function()
	it("a target position and a fallback may be an array or named x, y, z", function()
		local chain = {
			goal("a", { call = true }, { target = { position = { 1, 2, 3 } }, fallback = { 4, 5, 6 } }),
			goal(
				"b",
				{ call = true },
				{ target = { position = { x = 1, y = 2, z = 3 } }, fallback = { x = 4, y = 5, z = 6 } }
			),
			goal(
				"c",
				{ call = true },
				{ target = { position = { x = 1, y = 2, z = 3 } }, fallback = { 4, 5, 6 } }
			),
		}
		expect(Validate.check(chain, env())).toEqual({})
	end)

	it("Validate.position and Validate.toArray read both forms and refuse the rest", function()
		expect(Validate.position({ 1, 2, 3 })).toBe(true)
		expect(Validate.position({ x = 1, y = 2, z = 3 })).toBe(true)
		expect(Validate.toArray({ x = 1, y = 2, z = 3 })).toEqual({ 1, 2, 3 })
		expect(Validate.toArray({ 7, 8, 9 })).toEqual({ 7, 8, 9 })
		for _, bad in
			{
				{ 1, 2 },
				{ x = 1, y = 2 },
				{ x = 1, y = "2", z = 3 },
				{ x = 1, y = 2, z = 0 / 0 },
				{ 1, 2, math.huge },
				"x",
				5,
			}
		do
			expect(Validate.position(bad)).toBe(false)
			expect(Validate.toArray(bad)).toBe(nil)
		end
		expect(Validate.toArray(nil)).toBe(nil)
	end)

	it("a named position with a missing or non-numeric axis is refused, naming the goal", function()
		expectOne(
			Validate.check(
				{ goal("a", { call = true }, { target = { position = { x = 1, y = 2 } } }) },
				env()
			),
			"goal 'a'",
			"target.position must be three numbers"
		)
		expectOne(
			Validate.check({ goal("a", { call = true }, { fallback = { x = 1, y = 2, z = "3" } }) }, env()),
			"goal 'a'",
			"fallback must be three numbers"
		)
	end)
end)

describe("Goals validation: funnel warnings (not errors)", function()
	local chain = {
		goal("a", { call = true }, { funnel = "FirstCoins" }),
		goal("b", { call = true }, { funnel = "Missing" }),
		goal("c", { call = true }),
		goal("d", { call = true }, { funnel = "AlsoMissing" }),
	}

	it("names every goal whose funnel step isn't in analytics.funnel", function()
		local w = Validate.warnings(chain, { "Joined", "FirstCoins" })
		expect(#w).toBe(2)
		expect(has(w, "goal 'b': funnel step 'Missing' is not in GameConfig.analytics.funnel")).toBe(true)
		expect(has(w, "goal 'd': funnel step 'AlsoMissing'")).toBe(true)
	end)

	it("is not a boot error: check() stays empty for the same chain", function()
		expect(Validate.check(chain, env())).toEqual({})
	end)

	it(
		"no warning when every step is listed, when no goal has a step, or when the list is unknown",
		function()
			expect(Validate.warnings(chain, { "FirstCoins", "Missing", "AlsoMissing" })).toEqual({})
			expect(Validate.warnings({ goal("c", { call = true }) }, {})).toEqual({})
			expect(Validate.warnings(chain, nil)).toEqual({})
			expect(Validate.warnings(nil, { "Joined" })).toEqual({})
		end
	)
end)

describe("Goals validation: one bad chain per rule", function()
	it("a bad id, a duplicate id", function()
		expectOne(Validate.check({ goal("bad id", { call = true }) }, env()), "bad id")
		expectOne(
			Validate.check({ goal("a", { call = true }), goal("a", { ack = true }) }, env()),
			"duplicate id"
		)
	end)

	it("a check that isn't exactly one of the forms", function()
		expectOne(
			Validate.check({ goal("a", { call = true, ack = true }) }, env()),
			"exactly one of quest, source, call, ack"
		)
		expectOne(Validate.check({ goal("a", {}) }, env()), "exactly one of")
		expectOne(Validate.check({ goal("a", nil) }, env()), "check must be a table")
		expectOne(Validate.check({ goal("a", { call = "yes" }) }, env()), "check.call must be true")
		expectOne(Validate.check({ goal("a", { quest = "story1", on = "done" }) }, env()), "check.on must be")
	end)

	it("quest checks while Quests isn't enabled, an unknown quest, an objective it doesn't have", function()
		local noQuests = table.clone(ALL_ON)
		noQuests.Quests = false
		expectOne(
			Validate.check({ goal("a", { quest = "story1" }) }, env({ enabled = noQuests })),
			"needs Quests"
		)
		expectOne(Validate.check({ goal("a", { quest = "ghost" }) }, env()), "Quests has no quest 'ghost'")
		expectOne(
			Validate.check({ goal("a", { quest = "story1", objective = 3 }) }, env()),
			"has no objective 3"
		)
	end)

	it("an unknown source, and a built-in whose module is off", function()
		expectOne(
			Validate.check({ goal("a", { source = "mana", atLeast = 1 }) }, env()),
			"unknown source 'mana'"
		)
		for source, module in
			{ currency = "Economy", rebirths = "Rebirth", streakDay = "Streak", itemOwned = "Inventory" }
		do
			local enabled = table.clone(ALL_ON)
			enabled[module] = false
			expectOne(
				Validate.check(
					{ goal("a", { source = source, atLeast = 1, params = { item = "gem" } }) },
					env({ enabled = enabled })
				),
				"needs " .. module
			)
		end
		expectOne(
			Validate.check({ goal("a", { source = "itemOwned", atLeast = 1 }) }, env()),
			"needs params.item"
		)
	end)

	it("a non-finite atLeast", function()
		expectOne(
			Validate.check({ goal("a", { source = "currency", atLeast = math.huge }) }, env()),
			"atLeast must be a finite number"
		)
		expectOne(
			Validate.check({ goal("a", { source = "currency" }) }, env()),
			"atLeast must be a finite number"
		)
	end)

	it("a target that isn't one of the forms, a non-numeric position or fallback", function()
		expectOne(
			Validate.check({ goal("a", { call = true }, { target = { tag = "A", path = "B" } }) }, env()),
			"exactly one of tag, path, position, picker"
		)
		expectOne(
			Validate.check({ goal("a", { call = true }, { target = { area = "x" } }) }, env()),
			"exactly one of tag"
		)
		expectOne(
			Validate.check({ goal("a", { call = true }, { target = { position = { 1, "y", 3 } } }) }, env()),
			"target.position must be three numbers"
		)
		expectOne(
			Validate.check({ goal("a", { call = true }, { fallback = { 1, 2 } }) }, env()),
			"fallback must be three numbers"
		)
	end)

	it("more than 20 goals", function()
		local chain = {}
		for i = 1, 21 do
			table.insert(chain, goal("g" .. i, { call = true }))
		end
		expectOne(Validate.check(chain, env()), "at most 20")
	end)
end)

describe("Goals validation: all problems together", function()
	it("collects every problem", function()
		local errors = Validate.check({
			goal("bad id", { call = true }),
			goal("b", { source = "mana", atLeast = 1 }),
			goal("c", { call = true }, { fallback = "here" }),
		}, env())
		expect(#errors).toBe(3)
	end)

	it("fails the boot with every problem in one message, using Quests' real def", function()
		local _, err = StudWork.test.boot({
			modules = { F.Quests, F.Goals },
			config = {
				Quests = { quests = { once = F.oneTime() } },
				Goals = {
					chain = {
						goal("a", { quest = "ghost" }),
						goal("b", { source = "currency", atLeast = 1 }),
					},
				},
			},
		})
		expect(err).never.toBe(nil)
		expect(string.find(err, "Quests has no quest 'ghost'", 1, true) ~= nil).toBe(true)
		expect(string.find(err, "source 'currency' needs Economy", 1, true) ~= nil).toBe(true)
		local h, okErr = StudWork.test.boot({
			modules = { F.Quests, F.Goals },
			config = {
				Quests = { quests = { once = F.oneTime() } },
				Goals = { chain = { goal("a", { quest = "once", objective = 1 }) } },
			},
		})
		expect(okErr).toBe(nil)
		expect(h).never.toBe(nil)
	end)

	it("accepts a source registered by another module during init", function()
		local source = F.valueSource({ name = "power", quests = false, goals = true })
		local h = F.harness({
			modules = { F.Goals },
			probes = { source },
			config = { Goals = { chain = { goal("strong", { source = "power", atLeast = 5 }) } } },
		})
		expect(h:warnings()).toEqual({})
	end)
end)
