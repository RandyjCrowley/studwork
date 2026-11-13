--!strict
local Config = require(game:GetService("ReplicatedStorage").Modules.Companions.shared.Config)
describe("Companions config", function()
	it("accepts defaults and empty item opt-in", function()
		Config.validate(Config.defaults, { items = { { id = "pebble", companions = {} } } })
	end)
	it("rejects invalid boundaries, nonfinite values and nonreplicated flags", function()
		for key, value in
			{
				slots = 13,
				maxDrawn = -1,
				nearHz = math.huge,
				bobHeight = 0 / 0,
				assetsFolderName = "",
				nearDistance = 200,
				flag = "missing",
			}
		do
			local config: any = table.clone(Config.defaults)
			config[key] = value
			expect(pcall(Config.validate, config, { items = {} })).toBe(false)
		end
		local config: any = table.clone(Config.defaults)
		config.flag = "companions"
		expect(
			pcall(Config.validate, config, { flags = { companions = { default = true, serverOnly = true } } })
		).toBe(false)
		Config.validate(config, { flags = { companions = { default = true } } })
	end)
	it("validates server context flags through the public API", function()
		local config: any = table.clone(Config.defaults)
		config.flag = "companions"
		local flags = {
			isOn = function(name: string): boolean
				assert(name == "companions", "unknown flag")
				return false
			end,
		}
		Config.validate(config, { items = {} }, flags)
		config.flag = "missing"
		expect(pcall(Config.validate, config, { items = {} }, flags)).toBe(false)
		config.flag = "companions"
		expect(pcall(Config.validate, config, { items = {} })).toBe(false)
		-- A supplied declaration remains authoritative even when an API would accept the name.
		expect(pcall(Config.validate, config, { flags = {} }, flags)).toBe(false)
		expect(
			pcall(
				Config.validate,
				config,
				{ flags = { companions = { default = true, serverOnly = true } } },
				flags
			)
		).toBe(false)
	end)
	it("validates item namespace fields", function()
		local invalid: { any } = {
			{ movement = "swim" },
			{ score = math.huge },
			{ incomeBonus = -1 },
			{ hoverHeight = 1001 },
			{ triangles = 1.5 },
			{ look = string.rep("a", 65) },
			{ moveAnimation = "" },
		}
		for _, fields in invalid do
			expect(pcall(Config.validateItem, fields)).toBe(false)
		end
		Config.validateItem({ movement = "fly", score = 1e12, incomeBonus = 100, triangles = 1e9 })
	end)
end)
