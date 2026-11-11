-- Offline smoke test for the foundation-only config: valid, and StudWork resolves only the game's
-- own module with every kit module behind an erroring proxy.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(script.Parent.Config)
local FrameworkShared = ReplicatedStorage:WaitForChild("Framework")
local StudWork = require(FrameworkShared)
local ConfigValidate = require(FrameworkShared:WaitForChild("ConfigValidate"))
local Resolve = require(FrameworkShared:WaitForChild("Resolve"))
local Rebirth =
	require(ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Economy"):WaitForChild("Rebirth"))

local gameModule = StudWork.defineModule({
	name = "FoundationOnly",
	version = "1.0.0",
	framework = "^1.3.0",
	optional = { Rebirth },
	data = { key = Config.gameId, version = 1, default = { joins = 0 } },
})

describe("foundation-only Config", function()
	it("is a valid GameConfig with no modules", function()
		local order, errors = Resolve.resolve({ gameModule }, "1.3.0")
		assert(order, table.concat(errors or {}, "\n"))
		local config = table.clone(Config) :: any
		config.modules = { gameModule }
		local result = ConfigValidate.validate(order, config)
		if #result.errors > 0 then
			error(table.concat(result.errors, "\n"))
		end
		expect(#Config.modules).toBe(0)
		expect(#Config.items).toBe(0)
	end)

	it("boots only the foundation and proxies every module", function()
		local order = Resolve.resolve({ gameModule }, "1.3.0") :: { any }
		expect(#order).toBe(1) -- the game's own module; the framework services are not modules
		expect(order[1]).toBe(gameModule)
		-- boot it for real (the StudWork module harness): an optional module that isn't enabled is
		-- an erroring proxy, on ctx.deps and StudWork.use alike
		local Harness = (require :: any)(
			game:GetService("ServerScriptService"):WaitForChild("FrameworkTest"):WaitForChild("harness")
		)
		local seen: any = nil
		local h = Harness.new({
			gameId = Config.gameId,
			modules = { gameModule },
			events = Config.events,
			servers = {
				FoundationOnly = {
					init = function(ctx: any)
						seen = table.pack(pcall(function()
							return ctx.deps[Rebirth].rebirth
						end))
					end,
				},
			},
		})
		expect(seen[1]).toBe(false)
		expect(string.find(tostring(seen[2]), Resolve.notEnabledMessage("Rebirth"), 1, true) ~= nil).toBe(
			true
		)
		local ok, err = pcall(function()
			return h:use(Rebirth).rebirth
		end)
		expect(ok).toBe(false)
		expect(string.find(tostring(err), Resolve.notEnabledMessage("Rebirth"), 1, true) ~= nil).toBe(true)
		h:shutdown()
	end)
end)
