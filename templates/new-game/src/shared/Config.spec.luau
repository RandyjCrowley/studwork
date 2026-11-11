-- The game config must always pass StudWork's boot checks (StudWork.start refuses invalid
-- configs): module resolution with the game's own module, the framework ConfigValidate, and,
-- while the v1.2 services run behind the compat bridge, the v1.2 validator on the v1.2 view
-- the bridge hands them (V12Config.validateView; core-v1.3.0 step 4b-IIa, gone in Phase 2).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(script.Parent.Config)
local FrameworkShared = ReplicatedStorage:WaitForChild("Framework")
local ConfigValidate = require(FrameworkShared:WaitForChild("ConfigValidate"))
local Resolve = require(FrameworkShared:WaitForChild("Resolve"))
local V12Config = require(ReplicatedStorage:WaitForChild("CompatShared"):WaitForChild("V12Config"))

local function bootErrors(gameModule: any): { string }
	local modules = table.clone(Config.modules)
	table.insert(modules, gameModule)
	local order, errors = Resolve.resolve(modules, "1.3.0")
	if order == nil then
		return errors
	end
	local config = table.clone(Config) :: any
	config.modules = modules
	local result = ConfigValidate.validate(order, config)
	if #result.errors > 0 then
		return result.errors
	end
	return V12Config.validateView(V12Config.view(config, result.configs, gameModule))
end

describe("sandbox Config", function()
	it("is a valid GameConfig", function()
		local StudWork = require(FrameworkShared)
		-- the sandbox module's definition without its kit dependsOn list (that needs Rojo paths)
		local gameModule = StudWork.defineModule({
			name = "Sandbox",
			version = "1.0.0",
			framework = "^1.3.0",
			data = { key = Config.gameId, version = 1, default = { blockTouches = 0 } },
		})
		local errors = bootErrors(gameModule)
		if #errors > 0 then
			error(table.concat(errors, "\n"))
		end
		expect(#errors).toBe(0)
	end)
end)
