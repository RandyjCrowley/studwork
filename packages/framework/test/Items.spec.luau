--!nocheck
-- Items and namespaced item fields (§12), and the core-v1.3.0 "no item registration" rule.
local StudWork = require(script.Parent.Parent.shared)
local Harness = require(script.Parent.harness)
local ItemFields = require(script.Parent.Parent.shared.ItemFields)

local def = StudWork.defineModule

local Economy = def({
	name = "Economy",
	version = "1.0.0",
	framework = "^1.3.0",
	itemFields = {
		item = { economy = { incomePerSec = "number(0..)" } },
		mutation = { economy = { incomeMultiplier = "number" } },
	},
})
local Rival = def({
	name = "Rival",
	version = "1.0.0",
	framework = "^1.3.0",
	itemFields = { item = { economy = { other = "string" } } },
})

local items = {
	{ id = "pebble", name = "Pebble", rarity = "Common", tags = { "rock" } },
	{ id = "gold", name = "Gold", economy = { incomePerSec = 5 }, keepOnRebirth = true },
}

describe("item fields", function()
	it("accepts base fields plus enabled namespaces", function()
		local h = Harness.new({ modules = { Economy }, items = items })
		expect(h).Not.toBeNil()
	end)

	it("an undeclared namespace is a boot error naming the field", function()
		local _, err = Harness.boot({ modules = {}, items = items })
		expect(err).toContain(
			"items[2].economy: no enabled module declares the item field namespace 'economy'"
		)
	end)

	it("validates namespaced values and base fields, all errors together", function()
		local _, err = Harness.boot({
			modules = { Economy },
			items = {
				{ id = "a", name = "A", economy = { incomePerSec = -1 } },
				{ id = "a", name = 5, rarity = 3, tags = "rock" },
			},
		})
		expect(err).toContain("items[1].economy.incomePerSec")
		expect(err).toContain("items[2].id duplicate 'a'")
		expect(err).toContain("items[2].name: expected string")
		expect(err).toContain("items[2].rarity: expected string")
		expect(err).toContain("items[2].tags: expected {string}")
	end)

	it("two modules claiming the same namespace is a boot error", function()
		local _, err = Harness.boot({ modules = { Economy, Rival }, items = {} })
		expect(err).toContain("itemFields.item.economy is declared by both 'Economy' and 'Rival'")
	end)
end)

describe("no item registration in core-v1.3.0", function()
	local function walk(value, path, seen, hits)
		if type(value) ~= "table" or seen[value] then
			return
		end
		seen[value] = true
		for k, v in pairs(value) do
			local p = path .. "." .. tostring(k)
			if
				type(k) == "string"
				and type(v) == "function"
				and string.find(string.lower(k), "register", 1, true)
			then
				table.insert(hits, p)
			end
			walk(v, p, seen, hits)
		end
	end

	it("no register-named function on the item surfaces or the facade", function()
		local c
		Harness.new({
			modules = { Economy },
			items = items,
			servers = { Economy = {
				init = function(ctx)
					c = ctx
				end,
			} },
		})
		local hits = {}
		walk(c.gameConfig, "ctx.gameConfig", {}, hits)
		walk(StudWork, "StudWork", {}, hits)
		walk(ItemFields, "ItemFields", {}, hits)
		expect(table.concat(hits, ",")).toBe("")
		-- the only register* names on ctx are unrelated to items (currency spenders, random sources,
		-- console commands)
		local ctxHits = {}
		walk(c, "ctx", {}, ctxHits)
		table.sort(ctxHits)
		expect(table.concat(ctxHits, ",")).toBe(
			"ctx.compliance.registerCurrencySpender,ctx.compliance.registerRandomSource,ctx.console.register"
		)
	end)

	it("register-style calls error with the CHANGELOG message instead of no-op'ing", function()
		local c
		Harness.new({
			modules = { Economy },
			items = items,
			servers = { Economy = {
				init = function(ctx)
					c = ctx
				end,
			} },
		})
		local msg =
			"items must be declared in GameConfig.items; registering items after start is not supported in core-v1.3.0"
		expect(function()
			c.gameConfig.items.register({ id = "late", name = "Late" })
		end).toThrow(msg)
		expect(function()
			c.gameConfig.items.addItem({ id = "late", name = "Late" })
		end).toThrow(msg)
		expect(function()
			StudWork.registerItems({})
		end).toThrow(msg)
		expect(function()
			local _ = StudWork.Items
		end).toThrow(msg)
		expect(function()
			table.insert(c.gameConfig.items, { id = "late", name = "Late" })
		end).toThrow()
		expect(#c.gameConfig.items).toBe(2)
		expect(c.gameConfig.items.byId("gold").economy.incomePerSec).toBe(5)
		expect(table.isfrozen(c.gameConfig.items[2].economy)).toBe(true)
	end)
end)
