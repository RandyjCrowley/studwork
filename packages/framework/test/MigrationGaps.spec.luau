--!nocheck
--[[
	a gap in a module's migration numbers
	(between its first migration and data.version) is a boot error naming the missing number,
	instead of Migrate.run silently skipping that step.
]]
local Data = require(script.Parent.Parent.server.Data)
local Store = require(script.Parent.Parent.server.Store)
local Migrate = require(script.Parent.Parent.shared.Migrate)

local function step(old)
	return old
end

local function boot(dataSpec)
	return pcall(Data.new, {
		store = Store.memory(),
		modules = { { name = "Bag", data = dataSpec } },
		gameId = "g",
		now = function()
			return 1700000000
		end,
		log = function() end,
	})
end

describe("migration number gaps", function()
	it("a missing number between the first migration and data.version is a boot error naming it", function()
		local ok, err = boot({
			key = "bag",
			version = 4,
			default = {},
			migrations = { [1] = step, [2] = step, [4] = step },
		})
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("Bag: data.migrations has no migration 3")
	end)

	it("data.version bumped past the last migration is a gap too", function()
		local ok, err = boot({ key = "bag", version = 3, default = {}, migrations = { [1] = step } })
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("no migration 2, 3")
	end)

	it("a migration folder with a gap is caught the same way", function()
		-- a folder Instance stand-in (fromFolder treats plain tables as a migration table)
		local folder = setmetatable({}, {
			__index = {
				GetChildren = function()
					return { { Name = "001_init" }, { Name = "003_rename" } }
				end,
			},
		})
		local ok, err = pcall(Data.new, {
			store = Store.memory(),
			modules = {
				{ name = "Bag", data = { key = "bag", version = 3, default = {}, migrations = folder } },
			},
			gameId = "g",
			now = function()
				return 1
			end,
			log = function() end,
			require = function()
				return step
			end,
		})
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("no migration 2")
	end)

	it("no migrations, or contiguous ones starting anywhere, boot fine", function()
		expect((boot({ key = "bag", version = 3, default = {} }))).toBe(true)
		expect((boot({ key = "bag", version = 2, default = {}, migrations = { [2] = step } }))).toBe(true)
		expect((boot({ key = "bag", version = 3, default = {}, migrations = { [2] = step, [3] = step } }))).toBe(
			true
		)
		expect(#Migrate.gaps({ [1] = step, [2] = step }, 2)).toBe(0)
	end)
end)
