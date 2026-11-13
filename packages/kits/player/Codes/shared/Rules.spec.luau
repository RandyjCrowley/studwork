--!nocheck
local Rules = require(script.Parent.Rules)
local function definition()
	return { id = "launch", code = "WELCOME", rewards = { { kind = "currency", amount = 10 } } }
end
describe("promotion validation and recovery records", function()
	it("normalizes before lookup without accepting controls or excessive raw length", function()
		expect(Rules.normalize("  welcome  ")).toBe("WELCOME")
		expect(Rules.normalize("welcome\n")).toBe(nil)
		expect(Rules.normalize(string.rep(" ", 65) .. "A")).toBe(nil)
		expect(Rules.normalize("   ")).toBe(nil)
		expect(Rules.normalize({})).toBe(nil)
	end)
	it("hashes normalized analytics identities with exact 32-bit arithmetic", function()
		expect(Rules.hash("")).toBe("811c9dc5")
		expect(Rules.hash("hello")).toBe("4f9f2cab")
	end)
	it("rejects unsafe rewards and repeat definitions", function()
		local d = definition()
		expect(Rules.validateDefinition(d)).toBe(true)
		d.oncePerPlayer = false
		expect(Rules.validateDefinition(d)).toBe(false)
		d.oncePerPlayer = nil
		d.rewards[1].amount = 0 / 0
		expect(Rules.validateDefinition(d)).toBe(false)
		d.rewards[1] = { kind = "item", itemId = "hat", count = 0 }
		expect(Rules.validateDefinition(d)).toBe(false)
		d.rewards[1] = { kind = "custom", callback = function() end }
		expect(Rules.validateDefinition(d)).toBe(false)
	end)
	it("refuses duplicate normalized identities and malformed catalogs", function()
		local a, b = definition(), definition()
		b.id, b.code = "other", " welcome "
		expect(Rules.validateCatalog({ a, b })).toBe(false)
		expect(Rules.validateCatalog({ [2] = a })).toBe(false)
		b.code = "OTHER"
		expect(Rules.validateCatalog({ a, b })).toBe(true)
	end)
	it("preserves unresolved receipts even without catalog definitions", function()
		local clean = Rules.sanitize({
			redeemed = { old = true, bad = "yes" },
			pending = {
				retired = { token = "12:retired", capped = true },
				free = { token = "12:free", capped = false },
			},
			sequence = 7,
		})
		expect(clean.redeemed.old).toBe(true)
		expect(clean.redeemed.bad).toBe(nil)
		expect(clean.redeemed.retired).toBe(true)
		expect(clean.pending.retired.token).toBe("12:retired")
		expect(clean.pending.free.capped).toBe(false)
		expect(clean.sequence).toBe(7)
	end)
end)
