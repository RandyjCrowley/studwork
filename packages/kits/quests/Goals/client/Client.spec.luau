--!nocheck
-- Goals client part under FakeState (docs/framework/kits/quests.md, Goals "Client part"): goal()
-- and onChanged from extra.goal, the pill registered in the HUD, the pointer following the target
-- on its budget (StreamingEnabled fallbacks), setHidden firing skipGoals, and nothing forced: no
-- screen opened, no camera or GuiService.SelectedObject write.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local GoalsClientEnv = require("packages/kits/quests/tests/GoalsClientEnv.luau")
local Goals = require(Modules:WaitForChild("Goals"):WaitForChild("module"))

local CHAIN = {
	{ id = "coins", check = { call = true }, target = { tag = "Coin" } },
	{
		id = "tower",
		check = { call = true },
		target = { path = "Workspace.Tower" },
		fallback = { 600, 3, 0 },
	},
}

local E

-- a well-formed extra.goal wire table
local function wire(o)
	return {
		id = o.id,
		i = o.i or 1,
		n = o.n or 1,
		text = o.text or ("Goals.goal." .. o.id),
		target = o.target,
		next = false,
		hidden = o.hidden == true,
	}
end

local function start(w)
	E = GoalsClientEnv.new()
	if w then
		E:goal(w)
	end
	E:start({ config = { Goals = { chain = CHAIN } } })
	return StudWork.use(Goals)
end

afterEach(function()
	if E then
		E:stop()
	end
end)

describe("Goals client", function()
	it("registers the pill and reads goal() / onChanged from extra.goal", function()
		local goals = start(wire({ id = "coins", n = 2, target = { tag = "Coin" } }))
		expect(E.ui.registered["Goals.goal"]).never.toBeNil()
		expect(E.ui.registered["Goals.goal"].slot).toBe("topCenter")
		expect(goals.goal().id).toBe("coins")
		local seen = {}
		local off = goals.onChanged(function(view)
			table.insert(seen, view and view.id or "nil")
		end)
		E:goal(wire({ id = "tower", i = 2, n = 2, target = { path = "Workspace.Tower" } }))
		task.wait()
		expect(goals.goal().id).toBe("tower")
		expect(seen).toEqual({ "tower" })
		off()
		E:goal(nil)
		task.wait()
		expect(goals.goal()).toBeNil()
		expect(seen).toEqual({ "tower" })
	end)

	it(
		"points at the nearest tagged instance, on the budget, then the fallbacks when streamed out",
		function()
			local goals = start(wire({ id = "coins", n = 2, target = { tag = "Coin" } }))
			local coin = E:part("Coin1", 20, 3, 0, { "Coin" })
			E:advance(0.2)
			local info = goals.pointer()
			expect(info.from).toBe("instance")
			expect(info.position.X).toBe(20)
			expect(info.distance).toBe(20)
			expect(#E.beams).toBe(1)
			expect(E.beams[1].beam.Enabled).toBe(true)

			E:streamOut(coin)
			E:advance(0.2)
			expect(goals.pointer().from).toBe("lastKnown")

			-- the next goal: a path never streamed in on this client -> its config fallback
			E:goal(wire({ id = "tower", i = 2, n = 2, target = { path = "Workspace.Tower" } }))
			task.wait()
			E:advance(0.2)
			info = goals.pointer()
			expect(info.from).toBe("fallback")
			expect(info.position.X).toBe(600)
			expect(info.onScreen).toBe(false) -- far off to the side of the fake camera
			expect(#E.arrows).toBe(1)
			expect(E.arrows[1].Visible).toBe(true)
			expect(#E.beams).toBe(1) -- still one beam
		end
	)

	it("no target anywhere: the pill only (no beam, no arrow)", function()
		local goals = start(wire({ id = "coins", n = 2, target = { tag = "Coin" } }))
		E:advance(0.2)
		expect(goals.pointer().from).toBeNil()
		expect(#E.beams).toBe(0)
		expect(#E.arrows).toBe(0)
	end)

	it("hidden goals hide the pointer; setHidden fires skipGoals", function()
		local goals = start(wire({ id = "coins", n = 2, target = { tag = "Coin" } }))
		E:part("Coin1", 20, 3, 0, { "Coin" })
		E:advance(0.2)
		expect(E.beams[1].beam.Enabled).toBe(true)
		E:goal(wire({ id = "coins", n = 2, target = { tag = "Coin" }, hidden = true }))
		task.wait()
		E:advance(0.2)
		expect(E.beams[1].beam.Enabled).toBe(false)
		goals.setHidden(false)
		expect(E.fired[#E.fired].event).toBe("SkipGoals")
		expect(E.fired[#E.fired].args[1]).toBe(false)
	end)

	it("never forces anything: no screen, no camera write, no SelectedObject, nothing per frame", function()
		local goals = start(wire({ id = "coins", n = 2, target = { tag = "Coin" } }))
		E:part("Coin1", 20, 3, 0, { "Coin" })
		for _ = 1, 100 do -- 100 frames at 60 Hz, the character creeping 1 stud in total
			E.charPos = Vector3.new(E.charPos.X + 0.01, 3, 0)
			E:advance(1 / 60)
		end
		expect(goals.pointer().from).toBe("instance")
		expect(E.beamMoves >= 1).toBe(true)
		expect(E.beamMoves <= 3).toBe(true) -- moves only past half a stud, never per frame
		expect(E.ui.opened).toEqual({})
		expect(E.cameraWrites).toEqual({})
		expect(E.guiWrites).toEqual({})
	end)
end)
