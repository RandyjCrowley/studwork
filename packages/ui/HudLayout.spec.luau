local HudLayout = require(script.Parent.HudLayout)

local function W() end
local function X() end
local all = function()
	return true
end

describe("HudLayout.config (GameConfig.client.hud)", function()
	it("defaults to the default layout", function()
		expect(HudLayout.config(nil).mode).toBe("default")
		expect(HudLayout.config("default").mode).toBe("default")
	end)
	it("turns the HUD off with false", function()
		expect(HudLayout.config(false).mode).toBe("off")
		expect(HudLayout.config({ layout = false }).mode).toBe("off")
	end)
	it("replaces the layout with a component or a ModuleScript", function()
		local c = HudLayout.config(W)
		expect(c.mode).toBe("custom")
		expect(c.layout).toBe(W)
		local fakeModule = { Name = "MyHud" }
		local function load(m)
			expect(m).toBe(fakeModule)
			return X
		end
		local function isModule(v)
			return v == fakeModule
		end
		local m = HudLayout.config(fakeModule, load, isModule)
		expect(m.mode).toBe("custom")
		expect(m.layout).toBe(X)
		local both = HudLayout.config(
			{ layout = fakeModule, widgets = { ["Social.mailbox"] = false } },
			load,
			isModule
		)
		expect(both.layout).toBe(X)
		expect(both.widgets["Social.mailbox"]).toBe(false)
		expect(function()
			HudLayout.config(fakeModule, function()
				return 5
			end, isModule)
		end).toThrow("must return a React component")
	end)
	it("rejects other values", function()
		expect(function()
			HudLayout.config(5)
		end).toThrow("client.hud")
	end)
end)

describe("HudLayout.resolve (slots and widgets)", function()
	local defaults = {
		["Economy.currency"] = { slot = "topCenter", order = 1, module = "Economy", component = W },
		["Social.mailbox"] = { slot = "topCenter", order = 3, module = "Mail", component = W },
		["Game.nextGoal"] = { slot = "topCenter", order = 2, component = W },
	}

	it("places widgets in their slot, sorted by order, gated by module", function()
		local placed = HudLayout.resolve(defaults, {}, {}, function(name)
			return name == "Economy"
		end)
		expect(#placed.topCenter).toBe(2)
		expect(placed.topCenter[1].id).toBe("Economy.currency")
		expect(placed.topCenter[2].id).toBe("Game.nextGoal")
		for _, s in HudLayout.SLOTS do
			expect(placed[s]).never.toBeNil()
		end
	end)

	it("removes a widget with client.hud.widgets = { id = false }", function()
		local placed = HudLayout.resolve(defaults, {}, { ["Social.mailbox"] = false }, all)
		for _, w in placed.topCenter do
			expect(w.id).never.toBe("Social.mailbox")
		end
		expect(#placed.topCenter).toBe(2)
	end)

	it("lets modules contribute and games replace widgets", function()
		local placed = HudLayout.resolve(
			defaults,
			{ ["Streak.badge"] = { slot = "topLeft", component = X } },
			{ ["Economy.currency"] = { slot = "topRight", component = X } },
			all
		)
		expect(placed.topLeft[1].id).toBe("Streak.badge")
		expect(placed.topRight[1].spec.component).toBe(X)
		expect(#placed.topCenter).toBe(2)
	end)

	it("validates override specs", function()
		expect(function()
			HudLayout.resolve(defaults, {}, { ["A.b"] = { slot = "middle", component = W } }, all)
		end).toThrow("unknown slot 'middle'")
	end)
end)
