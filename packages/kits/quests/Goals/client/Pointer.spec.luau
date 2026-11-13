--!nocheck
-- Goals client pointer budget and HUD pieces (docs/framework/kits/quests.md, Goals "World beam",
-- "Edge arrow", "Pill"): one beam, no update below updateSeconds or half a stud, hidden near / far
-- / without a target; the edge arrow's placement; the pill and the arrow never Active or
-- Selectable; the pill's HUD slot doesn't collide with another topCenter widget.
local Pointer = require("packages/kits/quests/Goals/client/Pointer.luau")
local EdgeArrow = require("packages/kits/quests/Goals/client/EdgeArrow.luau")
local Pill = require("packages/kits/quests/Goals/client/Pill.luau")
local HudLayout = require("packages/ui/HudLayout.luau")
local GoalsClientEnv = require("packages/kits/quests/tests/GoalsClientEnv.luau")

local CONFIG = { beam = true, edgeArrow = true, updateSeconds = 0.1, nearStuds = 8, maxStuds = 2000 }

local function v(x, y, z)
	return Vector3.new(x, y, z)
end

describe("Goals Pointer (the beam)", function()
	it("builds exactly one beam and respects the update budget", function()
		local E = GoalsClientEnv.new()
		local p = Pointer.new({ build = E.env.buildBeam }, CONFIG)
		local target = v(50, 3, 0)
		expect(p:update(0, v(0, 3, 0), target, true)).toBe(true)
		expect(#E.beams).toBe(1)
		expect(E.beams[1].beam.Enabled).toBe(true)
		expect(E.beams[1].to.WorldPosition.X).toBe(50)
		expect(p:update(0.05, v(5, 3, 0), target, true)).toBe(false) -- below updateSeconds
		expect(p:update(0.2, v(0.3, 3, 0), target, true)).toBe(false) -- moved less than half a stud
		expect(p:update(0.3, v(0.6, 3, 0), target, true)).toBe(true) -- moved more
		expect(p:update(0.45, v(0.6, 3, 0), v(50.7, 3, 0), true)).toBe(true) -- the target moved
		expect(p.updates).toBe(3)
		for i = 1, 20 do
			p:update(0.5 + i * 0.1, v(0.6 + i, 3, 0), target, true)
		end
		expect(#E.beams).toBe(1) -- never a second beam
	end)

	it("hides within nearStuds, beyond maxStuds, without a target and while hidden", function()
		local E = GoalsClientEnv.new()
		local p = Pointer.new({ build = E.env.buildBeam }, CONFIG)
		p:update(0, v(0, 3, 0), v(50, 3, 0), true)
		p:update(1, v(0, 3, 0), v(5, 3, 0), true)
		expect(E.beams[1].beam.Enabled).toBe(false) -- near
		p:update(2, v(0, 3, 0), v(50, 3, 0), true)
		expect(E.beams[1].beam.Enabled).toBe(true)
		p:update(3, v(0, 3, 0), v(5000, 3, 0), true)
		expect(E.beams[1].beam.Enabled).toBe(false) -- far
		p:update(4, v(0, 3, 0), v(50, 3, 0), true)
		p:update(5, v(0, 3, 0), nil, true)
		expect(E.beams[1].beam.Enabled).toBe(false) -- no target
		p:update(6, v(0, 3, 0), v(50, 3, 0), false)
		expect(E.beams[1].beam.Enabled).toBe(false) -- hidden
	end)

	it("pointer.beam = false never builds a beam", function()
		local E = GoalsClientEnv.new()
		local cfg = table.clone(CONFIG)
		cfg.beam = false
		local p = Pointer.new({ build = E.env.buildBeam }, cfg)
		p:update(0, v(0, 3, 0), v(50, 3, 0), true)
		expect(#E.beams).toBe(0)
	end)
end)

describe("Goals EdgeArrow", function()
	it("is never Active, Selectable or Interactable", function()
		expect(EdgeArrow.PROPS.Active).toBe(false)
		expect(EdgeArrow.PROPS.Selectable).toBe(false)
		expect(EdgeArrow.PROPS.Interactable).toBe(false)
	end)

	it("hidden on screen; clamped to the edge and rotated toward an off-screen target", function()
		local size = { X = 667, Y = 375 }
		expect(EdgeArrow.place(v(300, 200, 10), size).visible).toBe(false)
		local right = EdgeArrow.place(v(5000, 187.5, 10), size)
		expect(right.visible).toBe(true)
		expect(math.abs(right.x - (667 - EdgeArrow.MARGIN)) < 0.01).toBe(true)
		expect(math.abs(right.rotation - 90) < 0.01).toBe(true) -- tip up at 0; clockwise 90 = right
		local above = EdgeArrow.place(v(333.5, -900, 10), size)
		expect(math.abs(above.y - EdgeArrow.MARGIN) < 0.01).toBe(true)
		expect(math.abs(above.rotation) < 0.01).toBe(true)
		-- behind the camera: mirrored, so a point "on screen" behind still shows an arrow
		local behind = EdgeArrow.place(v(400, 187.5, -10), size)
		expect(behind.visible).toBe(true)
		expect(behind.x < 333.5).toBe(true)
	end)

	it("eases toward the new place unless reduce motion is on", function()
		local E = GoalsClientEnv.new()
		local a = EdgeArrow.new({ build = E.env.buildArrow })
		a:update({ visible = true, x = 100, y = 100, rotation = 0 }, false)
		a:update({ visible = true, x = 200, y = 100, rotation = 0 }, false)
		expect(a.x).toBe(150)
		a:update({ visible = true, x = 300, y = 100, rotation = 0 }, true)
		expect(a.x).toBe(300) -- reduce motion: no easing
		a:update({ visible = false, x = 0, y = 0, rotation = 0 }, true)
		expect(E.arrows[1].Visible).toBe(false)
		expect(#E.arrows).toBe(1)
	end)
end)

describe("Goals Pill", function()
	it("is a non-Active, non-Selectable label", function()
		local props = Pill.labelProps("Goals.goal.first")
		expect(props.Active).toBe(false)
		expect(props.Selectable).toBe(false)
		expect(props.TextWrapped).toBe(false)
	end)

	it("registers as Goals.goal in topCenter at an order no other topCenter widget uses", function()
		expect(Pill.WIDGET_ID).toBe("Goals.goal")
		HudLayout.checkSpec(Pill.WIDGET_ID, Pill.widget)
		expect(Pill.widget.slot).toBe("topCenter")
		local used = { 1, 2, 3 } -- Economy.currency, Game.nextGoal, Social.mailbox
		expect(table.find(used, Pill.widget.order)).toBeNil()
		local placed = HudLayout.resolve({}, { [Pill.WIDGET_ID] = Pill.widget }, {}, function()
			return true
		end)
		local found = false
		for _, w in placed.topCenter do
			found = found or w.id == "Goals.goal"
		end
		expect(found).toBe(true)
	end)

	it("reads the view from extra.goal; hidden and absent goals draw nothing", function()
		expect(Pill.view(nil)).toBeNil()
		local view = Pill.view({ id = "a", i = 1, n = 3, text = "Goals.goal.a", next = false, hidden = true })
		expect(view.id).toBe("a")
		expect(view.hidden).toBe(true)
		expect(view.count).toBe(3)
		local state = {
			modules = { Goals = { extra = { goal = { text = "game.next.x", next = true, i = 3, n = 3 } } } },
		}
		expect(Pill.view(Pill.wireFrom(state)).isNext).toBe(true)
		expect(Pill.component({ state = { modules = {} } })).toBeNil() -- no goal: nothing rendered
	end)

	it("a chevron toward the widget's slot", function()
		expect(Pill.chevron("right")).toBe("→")
		expect(Pill.chevron("left")).toBe("←")
		expect(Pill.chevron("bottom")).toBe("↓")
		expect(Pill.chevron("topCenter")).toBeNil()
		expect(Pill.chevron(nil)).toBeNil()
	end)
end)
