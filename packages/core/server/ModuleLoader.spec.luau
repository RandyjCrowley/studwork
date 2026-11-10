local ModuleLoader = require(script.Parent.ModuleLoader)
local Modules = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Modules"))

local FOUNDATION_PLAN = { "Data", "Policy", "Events", "Shop", "Analytics", "Net" }

local function fakeAll(): { [string]: any }
	local all = {}
	for _, name in ModuleLoader.BOOT_ORDER do
		all[name] = { name = name }
	end
	return all
end

describe("ModuleLoader.plan", function()
	it("{} boots only the foundation", function()
		local plan = ModuleLoader.plan({})
		expect(plan).toEqual(FOUNDATION_PLAN)
	end)

	it("all modules boot in BOOT_ORDER", function()
		local plan = ModuleLoader.plan(Modules.MODULE_ORDER)
		expect(plan).toEqual(ModuleLoader.BOOT_ORDER)
	end)

	it("partial lists keep the relative order and always include the foundation", function()
		local plan = ModuleLoader.plan({ "Upgrades", "Economy", "Mail" })
		expect(plan).toEqual({
			"Data",
			"Policy",
			"Economy",
			"Upgrades",
			"Events",
			"Shop",
			"Analytics",
			"Mail",
			"Net",
		})
		for _, name in Modules.FOUNDATION do
			expect(table.find(plan :: any, name) ~= nil).toBe(true)
		end
	end)

	it("BOOT_ORDER covers every foundation service and module exactly once", function()
		local seen = {}
		for _, name in ModuleLoader.BOOT_ORDER do
			expect(seen[name]).toBe(nil)
			seen[name] = true
		end
		for _, name in Modules.FOUNDATION do
			expect(seen[name]).toBe(true)
		end
		for _, name in Modules.MODULE_ORDER do
			expect(seen[name]).toBe(true)
		end
	end)

	it("BOOT_ORDER puts every hard dependency first", function()
		for name, spec in Modules.SPECS do
			local at = table.find(ModuleLoader.BOOT_ORDER, name) :: number
			for _, dep in spec.requires do
				expect((table.find(ModuleLoader.BOOT_ORDER, dep) :: number) < at).toBe(true)
			end
		end
		expect(ModuleLoader.BOOT_ORDER[1]).toBe("Data")
	end)

	it("returns Modules.resolve's messages unchanged for unknown / missing dependencies", function()
		local plan, err = ModuleLoader.plan({ "Plot", "Nope" })
		expect(plan).toBe(nil)
		local _, errors = Modules.resolve({ "Plot", "Nope" })
		expect(err).toBe(table.concat(errors :: { string }, "\n"))
		expect(string.find(err :: string, "requires 'Inventory'", 1, true) ~= nil).toBe(true)
		expect(string.find(err :: string, "unknown module 'Nope'", 1, true) ~= nil).toBe(true)
	end)

	it("rejects a non-list", function()
		local plan, err = ModuleLoader.plan(nil)
		expect(plan).toBe(nil)
		expect(type(err)).toBe("string")
	end)
end)

describe("ModuleLoader.services", function()
	it("foundation services are the real modules, disabled ones are proxies", function()
		local all = fakeAll()
		local services = ModuleLoader.services(all, ModuleLoader.plan({ "Economy" }) :: { string })
		for _, name in Modules.FOUNDATION do
			expect(services[name]).toBe(all[name])
		end
		expect(services.Economy).toBe(all.Economy)
		expect(services.Rebirth == all.Rebirth).toBe(false)
	end)

	it("proxy field access errors with the not-enabled message", function()
		local services = ModuleLoader.services(fakeAll(), ModuleLoader.plan({}) :: { string })
		for _, name in Modules.MODULE_ORDER do
			local ok, err = pcall(function()
				return services[name].anything
			end)
			expect(ok).toBe(false)
			expect(string.find(tostring(err), Modules.notEnabledMessage(name), 1, true) ~= nil).toBe(true)
			local okWrite = pcall(function()
				services[name].x = 1
			end)
			expect(okWrite).toBe(false)
		end
	end)

	it("errors when a planned service has no implementation", function()
		local ok = pcall(ModuleLoader.services, { Data = {} }, { "Data", "Policy" })
		expect(ok).toBe(false)
	end)
end)

describe("ModuleLoader.isEnabledFn", function()
	it("foundation is always on, modules only when listed", function()
		local isEnabled = ModuleLoader.isEnabledFn({ "Economy" })
		expect(isEnabled("Data")).toBe(true)
		expect(isEnabled("Events")).toBe(true)
		expect(isEnabled("Economy")).toBe(true)
		expect(isEnabled("Rebirth")).toBe(false)
		expect(isEnabled("Nope")).toBe(false)
	end)
end)
