-- The game config must always pass StudWork's boot checks (StudWork.start refuses invalid
-- configs): module resolution with the game's own module and the framework ConfigValidate.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(script.Parent.Config)
local FrameworkShared = ReplicatedStorage:WaitForChild("Framework")
local ConfigValidate = require(FrameworkShared:WaitForChild("ConfigValidate"))
local Resolve = require(FrameworkShared:WaitForChild("Resolve"))

local function bootErrors(gameModule: any): { string }
	local modules = table.clone(Config.modules)
	table.insert(modules, gameModule)
	local order, errors = Resolve.resolve(modules, require(FrameworkShared).VERSION)
	if order == nil then
		return errors
	end
	local config = table.clone(Config) :: any
	config.modules = modules
	local result = ConfigValidate.validate(order, config)
	return result.errors
end

describe("sandbox Config", function()
	it("is a valid GameConfig", function()
		local StudWork = require(FrameworkShared)
		-- the sandbox module's definition without its kit dependsOn list (that needs Rojo paths)
		local gameModule = StudWork.defineModule({
			name = "Sandbox",
			version = "1.0.0",
			framework = "^" .. StudWork.VERSION, -- the framework this game is built on
			data = { key = Config.gameId, version = 1, default = { blockTouches = 0 } },
		})
		local errors = bootErrors(gameModule)
		if #errors > 0 then
			error(table.concat(errors, "\n"))
		end
		expect(#errors).toBe(0)
	end)
end)
