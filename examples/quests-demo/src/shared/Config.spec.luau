--!nocheck
-- The demo's config must always pass StudWork's boot checks (module resolution with the game's own
-- module and the framework ConfigValidate), list every goal's funnel step, and declare every
-- game.* string key its quests and goals use.
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
	return ConfigValidate.validate(order, config).errors
end

describe("quests-demo Config", function()
	it("is a valid GameConfig", function()
		local StudWork = require(FrameworkShared)
		local gameModule = StudWork.defineModule({
			name = "QuestsDemo",
			version = "1.0.0",
			framework = "^1.7.0",
			data = { key = Config.gameId, version = 1, default = { coinTouches = 0 } },
		})
		expect(bootErrors(gameModule)).toEqual({})
	end)

	it("lists every goal's funnel step in analytics.funnel, in chain order, after Joined", function()
		local steps = { "Joined" }
		for _, goal in Config.config.Goals.chain do
			table.insert(steps, goal.funnel)
		end
		expect(Config.analytics.funnel).toEqual(steps)
	end)

	it("declares every game.* key its quests, objectives and goals use", function()
		local used = { "game.next.dailies" }
		for _, q in Config.config.Quests.quests do
			table.insert(used, q.title)
			for _, o in q.objectives do
				expect(type(o.label)).toBe("string") -- every objective has a label
				table.insert(used, o.label)
			end
		end
		for _, goal in Config.config.Goals.chain do
			table.insert(used, goal.text)
		end
		for _, key in used do
			expect(key .. "=" .. tostring(Config.strings[key] ~= nil)).toBe(key .. "=true")
		end
	end)

	it("uses only a free roll table (no paid = true, no cost)", function()
		local crate = Config.config.Rarity.rarityTables.DemoCrate
		expect(crate.paid).toBe(nil)
		expect(crate.cost).toBe(nil)
		expect(Config.compliance.paidCurrencies).toEqual({})
	end)
end)
