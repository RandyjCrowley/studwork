local Modules = require(script.Parent.Modules)

describe("Modules manifest", function()
	it("lists every module once in MODULE_ORDER with a spec", function()
		local seen = {}
		for _, name in Modules.MODULE_ORDER do
			expect(seen[name]).toBe(nil)
			seen[name] = true
			expect(Modules.SPECS[name] ~= nil).toBe(true)
		end
		for name in Modules.SPECS do
			expect(seen[name]).toBe(true)
		end
	end)

	it("MODULE_ORDER puts every hard dependency first", function()
		local position = {}
		for i, name in Modules.MODULE_ORDER do
			position[name] = i
		end
		for name, spec in Modules.SPECS do
			for _, dep in spec.requires do
				expect(position[dep] ~= nil).toBe(true)
				expect(position[dep] < position[name]).toBe(true)
			end
			for _, dep in spec.optional do
				expect(Modules.isModule(dep)).toBe(true)
			end
		end
	end)

	it("has an API list for every foundation service and module", function()
		for _, name in Modules.FOUNDATION do
			expect(#Modules.API[name] > 0).toBe(true)
		end
		for name in Modules.SPECS do
			expect(#Modules.API[name] > 0).toBe(true)
		end
	end)
end)

describe("Modules.resolve", function()
	it("accepts {} (foundation only)", function()
		local order, errors = Modules.resolve({})
		expect(errors).toBe(nil)
		expect(#(order :: any)).toBe(0)
	end)

	it("returns dependencies first regardless of list order", function()
		local order = Modules.resolve({ "Plot", "Inventory", "Items" }) :: { string }
		expect(order[1]).toBe("Items")
		expect(order[2]).toBe("Inventory")
		expect(order[3]).toBe("Plot")
	end)

	it("rejects a missing dependency with a clear message", function()
		local order, errors = Modules.resolve({ "Rebirth" })
		expect(order).toBe(nil)
		expect((errors :: any)[1]).toContain("module 'Rebirth' requires 'Economy'")
	end)

	it("rejects unknown names, foundation names and duplicates", function()
		local _, errors = Modules.resolve({ "Items", "Items", "Shop", "Pets" })
		local text = table.concat(errors :: any, "\n")
		expect(text).toContain("listed twice")
		expect(text).toContain("'Shop' is foundation")
		expect(text).toContain("unknown module 'Pets'")
	end)

	it("rejects a non-list", function()
		local _, errors = Modules.resolve(nil)
		expect((errors :: any)[1]).toContain("modules must be a list")
	end)

	it("formats the not-enabled message", function()
		expect(Modules.notEnabledMessage("Rebirth")).toBe("Rebirth is not enabled in GameConfig.modules")
	end)
end)
