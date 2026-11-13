--!nocheck
-- The gate's first-session sim (docs/framework/kits/quests.md, "Testing your first session"): the
-- quests demo boots in the multi-server sim, a new player plays 3 scripted minutes with the calls
-- the demo's world makes, and every goal's funnel step is logged exactly once, with no kick, no
-- error and no warning. A second check starts the Quests and Goals client parts on the goals the
-- server produced: no screen opened, the camera and GuiService.SelectedObject untouched.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local GoalsClientEnv = require("packages/kits/quests/tests/GoalsClientEnv.luau")
local F = StudWork.test.sim

-- relative to where tools/test runs (the repo root here)
local PROJECT = "examples/quests-demo/default.project.json"
local STEPS = { "FirstCoins", "OpenedBoard", "FirstClaim", "ReachedTower" } -- the demo's analytics.funnel steps

local function funnelCount(server, step: string): number
	local n = 0
	for _, c in server.calls do
		if c.service == "Analytics" and c.fn == "funnel" and table.find(c.args, step) then
			n += 1
		end
	end
	return n
end

-- the extra.goal wire for a server-side GoalView
local function wireOf(view)
	if view == nil then
		return nil
	end
	return {
		id = view.id,
		i = view.index,
		n = view.count,
		text = view.text,
		args = view.args,
		target = view.target,
		widget = view.widget,
		next = view.isNext,
		hidden = view.hidden,
	}
end

describe("quests-demo first session", function()
	it("a new player's first 3 minutes: every goal once, nothing blocking", function()
		local world = F.world()
		local server = F.gameServer(world, PROJECT)
		local p = server:join(101)
		assert(
			world:advanceUntil(function()
				return server:isLoaded(p)
			end, 30),
			"loaded"
		)
		local Goals = server:use("Goals")
		expect(Goals.current(p).id).toBe("firstCoins") -- the pill shows the first goal at once
		expect(Goals.current(p).target).toEqual({ tag = "DemoCoin" })

		-- the player's first 3 minutes, scripted with what the demo's world does on the server
		server:use("Economy").grant(p, 25, "demo:coin") -- picked up coins (DemoCoin touches)
		server:use("Quests").progress(p, "coinTouched")
		world:advance(2)
		expect(Goals.current(p).id).toBe("openBoard")
		server:action(p, "Goals", "ackGoal", "openBoard") -- the demo client acks when the board opens
		server:use("Quests").progress(p, "guideVisited") -- touched the guide
		world:advance(2)
		server:action(p, "Quests", "claimQuest", "story1")
		Goals.complete(p, "reachTower") -- the demo's tower touch
		world:advance(180)

		for _, step in STEPS do
			expect(funnelCount(server, step)).toBe(1)
		end
		local after = Goals.current(p)
		expect(after == nil or after.isNext).toBe(true) -- chain done
		expect(after.text).toBe("game.next.dailies") -- the demo's setNext
		expect(server:isLoaded(p)).toBe(true) -- not kicked
		expect(world:errors()).toEqual({})
		expect(server.warnings).toEqual({})
	end)

	it("the Quests and Goals client parts never open a screen or touch the camera or selection", function()
		local world = F.world()
		local server = F.gameServer(world, PROJECT)
		local p = server:join(102)
		assert(
			world:advanceUntil(function()
				return server:isLoaded(p)
			end, 30),
			"loaded"
		)
		local Goals = server:use("Goals")

		local E = GoalsClientEnv.new() -- 667 x 375
		E:goal(wireOf(Goals.current(p)))
		E:start({ config = { Goals = Config.config.Goals } })
		E:part("DemoCoin1", 12, 3, 4, { "DemoCoin" })
		for _ = 1, 3 * 60 * 10 do -- 3 minutes of client frames at 10 Hz
			E:advance(0.1)
		end
		server:use("Economy").grant(p, 25, "demo:coin")
		world:advance(2)
		E:goal(wireOf(Goals.current(p)))
		for _ = 1, 50 do
			E:advance(0.1)
		end
		E:stop()

		expect(E.ui.opened).toEqual({}) -- no screen opened
		expect(E.cameraWrites).toEqual({}) -- the camera only read
		expect(E.guiWrites).toEqual({}) -- GuiService.SelectedObject untouched
		expect(#E.beams <= 1).toBe(true)
		expect(world:errors()).toEqual({})
	end)
end)
