local ItemValidate = require(script.Parent.ItemValidate)

local function good(overrides: { [string]: any }?): { [string]: any }
	local def: { [string]: any } = { id = "pebble", name = "Pebble", rarity = "Common", incomePerSec = 1 }
	for k, v in (overrides or {}) :: { [string]: any } do
		def[k] = v
	end
	return def
end

local function never(_id: string): boolean
	return false
end

describe("ItemValidate", function()
	it("accepts a valid def with optional fields", function()
		expect(ItemValidate.validateDef(good())).toBeNil()
		expect(
			ItemValidate.validateDef(
				good({ tags = { "Shelf", "Plant" }, model = "M", icon = "rbxassetid://1" })
			)
		).toBeNil()
		expect(ItemValidate.validateDef(good({ incomePerSec = 0 }))).toBeNil()
	end)

	it("rejects bad ids", function()
		expect(ItemValidate.validateDef(good({ id = "" }))).toContain("invalid item id")
		expect(ItemValidate.validateDef(good({ id = 5 }))).toContain("invalid item id")
		expect(ItemValidate.validateDef(good({ id = "has space" }))).toContain("invalid item id")
		expect(ItemValidate.validateDef(good({ id = string.rep("a", 65) }))).toContain("invalid item id")
	end)

	it("rejects bad rarity, income, name and tags", function()
		expect(ItemValidate.validateDef(good({ rarity = "Ultra" }))).toContain("unknown rarity")
		expect(ItemValidate.validateDef(good({ incomePerSec = -1 }))).toContain("incomePerSec")
		expect(ItemValidate.validateDef(good({ incomePerSec = 0 / 0 }))).toContain("incomePerSec")
		expect(ItemValidate.validateDef(good({ incomePerSec = math.huge }))).toContain("incomePerSec")
		expect(ItemValidate.validateDef(good({ incomePerSec = "1" }))).toContain("incomePerSec")
		expect(ItemValidate.validateDef(good({ name = "" }))).toContain("name")
		expect(ItemValidate.validateDef(good({ tags = "Shelf" }))).toContain("tags")
		expect(ItemValidate.validateDef(good({ tags = { "ok", 3 } }))).toContain("tags")
		expect(ItemValidate.validateDef(good({ tags = { a = "x" } }))).toContain("tags")
		expect(ItemValidate.validateDef(good({ model = 4 }))).toContain("model")
		expect(ItemValidate.validateDef("nope")).toContain("must be a table")
	end)

	it("rejects duplicates inside a batch and against existing ids", function()
		local ok, err = ItemValidate.validateBatch({ good(), good() }, never)
		expect(ok).toBe(false)
		expect(err).toContain("duplicate item id 'pebble'")
		ok, err = ItemValidate.validateBatch({ good() }, function(id)
			return id == "pebble"
		end)
		expect(ok).toBe(false)
		expect(err).toContain("duplicate")
		ok = ItemValidate.validateBatch({ good(), good({ id = "twig" }) }, never)
		expect(ok).toBe(true)
	end)

	it("rejects non-arrays", function()
		expect((ItemValidate.validateBatch(nil, never))).toBe(false)
		expect((ItemValidate.validateBatch({ x = good() }, never))).toBe(false)
	end)
end)
