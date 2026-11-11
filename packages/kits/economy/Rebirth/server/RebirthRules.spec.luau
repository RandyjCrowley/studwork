--!nocheck
-- Rebirth inventory rules (Rebirth.keeps, pure) and their compliance limits in the definition.
local Rebirth = require(script.Parent)
local RebirthRef = require(
	game:GetService("ReplicatedStorage")
		:WaitForChild("Modules")
		:WaitForChild("Rebirth")
		:WaitForChild("module")
)

local DEFAULT = Rebirth.DEFAULT_RULES
local def = {} -- an item without keepOnRebirth
local keepDef = { keepOnRebirth = true }
local wipeDef = { keepOnRebirth = false }

local function copy(source: string?): any
	return { itemId = "x", uid = "u", source = source }
end

describe("Rebirth.keeps (defaults = the v1.2 rules)", function()
	it("keeps paid:, wipes paidcur: and earned copies, keeps unknown items", function()
		expect(Rebirth.keeps(def, copy("paid:Egg"), DEFAULT)).toBe(true)
		expect(Rebirth.keeps(def, copy("paidcur:Chest"), DEFAULT)).toBe(false)
		expect(Rebirth.keeps(def, copy("drop"), DEFAULT)).toBe(false)
		expect(Rebirth.keeps(def, copy(nil), DEFAULT)).toBe(false)
		expect(Rebirth.keeps(nil, copy("drop"), DEFAULT)).toBe(true)
	end)

	it("ItemDef.keepOnRebirth overrides earned/paidcur, never a Robux copy", function()
		expect(Rebirth.keeps(keepDef, copy("drop"), DEFAULT)).toBe(true)
		expect(Rebirth.keeps(keepDef, copy("paidcur:Chest"), DEFAULT)).toBe(true)
		expect(Rebirth.keeps(wipeDef, copy("drop"), DEFAULT)).toBe(false)
		-- v1.2 wiped a paid copy of a keepOnRebirth = false item; v1.3 never wipes Robux copies
		expect(Rebirth.keeps(wipeDef, copy("paid:Egg"), DEFAULT)).toBe(true)
	end)

	it("config can keep paidcur: / earned copies and ignore item flags", function()
		local keepAll = { paid = "keep", paidCurrency = "keep", earned = "keep", itemOverrides = false }
		expect(Rebirth.keeps(def, copy("paidcur:Chest"), keepAll)).toBe(true)
		expect(Rebirth.keeps(def, copy("drop"), keepAll)).toBe(true)
		expect(Rebirth.keeps(wipeDef, copy("drop"), keepAll)).toBe(true)
		local noFlags = { paid = "keep", paidCurrency = "wipe", earned = "wipe", itemOverrides = false }
		expect(Rebirth.keeps(keepDef, copy("drop"), noFlags)).toBe(false)
		expect(Rebirth.keeps(wipeDef, copy("paid:Egg"), noFlags)).toBe(true)
	end)
end)

describe("Rebirth config (definition)", function()
	it('defaults to the v1.2 rules, and onRebirth.paid accepts only "keep"', function()
		local defaults = RebirthRef.config.defaults.onRebirth
		expect(defaults.paid).toBe("keep")
		expect(defaults.paidCurrency).toBe("wipe")
		expect(defaults.earned).toBe("wipe")
		expect(defaults.itemOverrides).toBe(true)
		expect(RebirthRef.config.schema.onRebirth.paid.type).toBe("enum(keep)")
	end)
end)
