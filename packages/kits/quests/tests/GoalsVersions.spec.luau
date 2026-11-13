--!nocheck
-- Goals: saves across chain versions (docs/framework/kits/quests.md, Goals "How the chain moves" and
-- "Save data"): a removed goal id in an old save is pruned in the load tx; a chain changed between
-- versions is re-checked; a finished player stays finished; a returning player (sessions > 1)
-- with a new section starts finished with no funnel steps.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local G = require("packages/kits/quests/tests/GoalsHelpers.luau")
local F = G.F
local Goals, Economy = G.Goals, G.Economy

local V1 = {
	{ id = "a", check = { call = true }, funnel = "StepA" },
	{ id = "gone", check = { call = true }, funnel = "StepGone" },
	{ id = "b", check = { call = true }, funnel = "StepB" },
}

-- a save made by a first server (one session), with its goals section replaced
local function oldSave(userId, goalsSection, before)
	local h = G.boot({ chain = V1 })
	local p = h:addPlayer({ userId = userId })
	if before then
		before(h, p)
	end
	h:tick(1)
	h:removePlayer(p)
	local save = h:saved(p)
	save.goals = goalsSection
	return save
end

describe("Goals versions", function()
	it("drops a removed goal id from an old save in the load tx (never crashes the load)", function()
		local save = oldSave(
			1,
			{ done = { a = true, gone = true, renamedAway = true }, fin = false, hide = false, v = 1 }
		)
		local h = G.boot({ chain = { V1[1], V1[3] } })
		local p = h:addPlayer({ userId = 1, data = save })
		expect(p.loaded).toBe(true)
		expect(p.kicked).toBeFalsy()
		expect(h:use(Goals).current(p).id).toBe("b")
		expect(h:use(Goals).current(p).count).toBe(2)
		h:removePlayer(p)
		expect(h:saved(p).goals.done).toEqual({ a = true })
		expect(h:saved(p).goals.v).toBe(1)
	end)

	it(
		"a chain changed between versions: v updated, the current goal recomputed, not-done goals checked once",
		function()
			local save = oldSave(
				2,
				{ done = { a = true }, fin = false, hide = false, v = 1 },
				function(h0, p0)
					h0:use(Economy).grant(p0, 10, "test") -- already rich before the chain changed
				end
			)
			local v2 = {
				{ id = "a", check = { call = true }, funnel = "StepA" },
				{ id = "rich", check = { source = "currency", atLeast = 5 }, funnel = "StepRich" },
				{ id = "b", check = { call = true }, funnel = "StepB" },
			}
			local h = G.boot({ chain = v2, goals = { chainVersion = 2 } })
			local p = h:addPlayer({ userId = 2, data = save })
			expect(h:use(Economy).balance(p)).toBe(10)
			expect(h:use(Goals).current(p).id).toBe("rich")
			h:tick(1)
			expect(h:use(Goals).current(p).id).toBe("b") -- rich was already met: checked on load
			expect(G.funnels(h, p)).toEqual({ "StepRich" })
			h:removePlayer(p)
			expect(h:saved(p).goals.v).toBe(2)
		end
	)

	it("a player who finished the old chain stays finished when goals are added", function()
		local save =
			oldSave(3, { done = { a = true, gone = true, b = true }, fin = true, hide = false, v = 1 })
		local v2 = table.clone(V1)
		table.insert(v2, { id = "newGoal", check = { call = true }, funnel = "StepNew" })
		local h = G.boot({ chain = v2, goals = { chainVersion = 2 } })
		local log = G.signalLog(h)
		local p = h:addPlayer({ userId = 3, data = save })
		h:tick(2)
		expect(h:use(Goals).current(p)).toBeNil()
		expect(select(2, h:use(Goals).complete(p, "newGoal"))).toBe("done")
		h:tick(1)
		expect(G.funnels(h, p)).toEqual({})
		expect(log.done).toBe(0)
		h:removePlayer(p)
		expect(h:saved(p).goals.fin).toBe(true)
		expect(h:saved(p).goals.v).toBe(2)
	end)

	it(
		"a returning player (sessions > 1) with a new goals section starts finished, no funnel steps",
		function()
			-- first session in a version of the game without Goals
			local first = F.harness({ modules = { Economy }, config = { Economy = F.economy() } })
			local p0 = first:addPlayer({ userId = 4 })
			first:removePlayer(p0)
			local save = first:saved(p0)
			expect(save.goals).toBeNil()

			local h = G.boot({ chain = V1 })
			local log = G.signalLog(h)
			local p = h:addPlayer({ userId = 4, data = save })
			h:tick(2)
			expect(h:use(Goals).current(p)).toBeNil()
			expect(G.funnels(h, p)).toEqual({})
			expect(log.done).toBe(0)
			expect(#log.changed).toBe(0)
			h:removePlayer(p)
			expect(h:saved(p).goals.fin).toBe(true)
			expect(h:saved(p).goals.v).toBe(1)
		end
	)

	it("a returning player still gets the setNext provider", function()
		local first = F.harness({ modules = { Economy }, config = { Economy = F.economy() } })
		local p0 = first:addPlayer({ userId = 5 })
		first:removePlayer(p0)
		local h = G.boot({ chain = V1 })
		h:use(Goals).setNext(function()
			return { text = "game.next.x" }
		end)
		local p = h:addPlayer({ userId = 5, data = first:saved(p0) })
		local view = h:use(Goals).current(p)
		expect(view.isNext).toBe(true)
		expect(view.text).toBe("game.next.x")
	end)

	it("a new player (sessions == 1) starts the chain; v becomes chainVersion", function()
		local h = G.boot({ chain = V1, goals = { chainVersion = 7 } })
		local p = h:addPlayer({ userId = 6 })
		expect(h:use(Goals).current(p).id).toBe("a")
		h:removePlayer(p)
		expect(h:saved(p).goals.v).toBe(7)
		expect(h:saved(p).goals.fin).toBe(false)
	end)

	it("setChain replaces the config chain before any player loads, validated the same way", function()
		local probe = {
			ref = StudWork.defineModule({
				name = "ChainProbe",
				version = "1.0.0",
				framework = "^1.7.0",
				optional = { Goals },
			}),
		}
		probe.part = {
			start = function(ctx)
				ctx.deps[Goals].setChain({ { id = "coded", check = { call = true } } }, 3)
				local ok = pcall(ctx.deps[Goals].setChain, { { id = "bad id!", check = { call = true } } })
				probe.badRefused = not ok
			end,
		}
		local h = G.boot({ chain = V1, probes = { probe } })
		expect(probe.badRefused).toBe(true)
		local p = h:addPlayer({ userId = 7 })
		expect(h:use(Goals).current(p).id).toBe("coded")
		expect(pcall(h:use(Goals).setChain, { { id = "late", check = { call = true } } })).toBe(false)
		h:removePlayer(p)
		expect(h:saved(p).goals.v).toBe(3)
	end)
end)
