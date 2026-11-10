-- Offline smoke test for the foundation-only config: valid, and the loader plan boots only the
-- foundation with every optional module behind an erroring proxy.
local Config = require(script.Parent.Config)
local ConfigValidate =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("ConfigValidate"))
local Modules = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Modules"))
local ModuleLoader =
	require(game:GetService("ServerScriptService"):WaitForChild("CoreServer"):WaitForChild("ModuleLoader"))

describe("foundation-only Config", function()
	it("is a valid GameConfig with no modules", function()
		local errors = ConfigValidate.validate(Config)
		if #errors > 0 then
			error(table.concat(errors, "\n"))
		end
		expect(#Config.modules).toBe(0)
		expect(#Config.items).toBe(0)
	end)

	it("boots only the foundation and proxies every module", function()
		local plan = ModuleLoader.plan(Config.modules) :: { string }
		expect(#plan).toBe(#Modules.FOUNDATION)
		for _, name in Modules.FOUNDATION do
			expect(table.find(plan, name) ~= nil).toBe(true)
		end
		local all = {}
		for _, name in ModuleLoader.BOOT_ORDER do
			all[name] = {}
		end
		local services = ModuleLoader.services(all, plan)
		local ok, err = pcall(function()
			return services.Rebirth.rebirth
		end)
		expect(ok).toBe(false)
		expect(string.find(tostring(err), Modules.notEnabledMessage("Rebirth"), 1, true) ~= nil).toBe(true)
	end)
end)
