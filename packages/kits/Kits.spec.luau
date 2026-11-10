--!nocheck
-- core-v1.3.0 Phase 0 step 5: the kits' thin defineModule wrappers resolve and boot through the
-- framework loader (stub server parts; the real v1.2 services need Roblox and are covered by
-- their own specs + the multi-server sim).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Harness = require("packages/framework/test/harness.luau")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local KITS = {
	Collection = { "Items", "Inventory", "Rarity" },
	Economy = { "Economy", "Upgrades", "Rebirth", "Offline" },
	Base = { "Plot" },
	Social = { "Friends", "Mail" },
	Engagement = { "Streak" },
}

local refs, servers, names = {}, {}, {}
for kit, list in KITS do
	for _, name in list do
		local ref = require(ReplicatedStorage:WaitForChild("Kits"):WaitForChild(kit):WaitForChild(name))
		refs[name] = ref
		servers[name] = { api = {
			kit = function()
				return kit
			end,
		} }
		table.insert(names, name)
	end
end
table.sort(names)

describe("kit module wrappers (Phase 0 step 5)", function()
	it("every v1.2 service has a valid ModuleRef named after it", function()
		expect(#names).toBe(11)
		for name, ref in refs do
			expect(StudWork.isModuleRef(ref)).toBe(true)
			expect(ref.name).toBe(name)
		end
	end)

	it("all eleven boot together through the framework loader, deps before dependents", function()
		local list = {}
		for _, name in names do
			table.insert(list, refs[name])
		end
		local h = Harness.new({ modules = list, servers = servers })
		local order = {}
		for i, ref in h.runtime.order do
			order[ref.name] = i
		end
		expect(order.Items < order.Inventory).toBe(true)
		expect(order.Items < order.Rarity).toBe(true)
		expect(order.Inventory < order.Plot).toBe(true)
		expect(order.Economy < order.Upgrades).toBe(true)
		expect(order.Economy < order.Rebirth).toBe(true)
		expect(h:use(refs.Plot).kit()).toBe("Base")
	end)

	it("a dependent without its hard dependency fails boot", function()
		local h, err = Harness.boot({ modules = { refs.Plot }, servers = servers })
		expect(h).toBe(nil)
		expect(string.find(tostring(err), "Inventory", 1, true) ~= nil).toBe(true)
	end)
end)
