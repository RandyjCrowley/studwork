--!nocheck
local Schema = require(script.Parent.Schema)
describe("preference schema validation", function()
	it("resolves independent built-ins and explicit omission/override", function()
		local defs = Schema.resolve({ builtins = { haptics = false, musicVolume = { default = 0.5 } } })
		expect(defs.haptics).toBe(nil)
		expect(defs.musicVolume.default).toBe(0.5)
		expect(defs.effectsVolume.default).toBe(1)
		expect(defs.reduceMotion.scope).toBe("client")
		expect(defs.showTips.scope).toBe("saved")
		expect(Schema.resolve().musicVolume.default).toBe(1)
	end)
	it("rejects nonfinite, out-of-range and off-step writes", function()
		local def = Schema.resolve().musicVolume
		expect(Schema.validate(def, 0.55)).toBe(true)
		expect(Schema.validate(def, 0.56)).toBe(false)
		expect(Schema.validate(def, 2)).toBe(false)
		expect(Schema.validate(def, 0 / 0)).toBe(false)
		expect(Schema.validate(def, "1")).toBe(false)
		expect(Schema.validate(Schema.resolve().haptics, 1)).toBe(false)
		expect(Schema.validate(Schema.resolve().textSize, "unknown")).toBe(false)
	end)
	it("rejects invalid defaults, duplicate ids and unbounded schemas", function()
		local def = {
			id = "custom",
			type = "choice",
			choices = { "a", "b" },
			default = "x",
			category = "gameplay",
			labelKey = "game.custom",
			scope = "saved",
		}
		expect(Schema.validateDefinition(def)).toBe(false)
		def.default = "a"
		expect(Schema.validateDefinition(def)).toBe(true)
		expect(pcall(Schema.resolve, { schema = { def, def } })).toBe(false)
		expect(pcall(Schema.resolve, { maxSettings = 1 })).toBe(false)
	end)
	it("decodes only the configured exact wire kind and validates the value", function()
		local def = Schema.resolve().musicVolume
		local kind, b, n, s = Schema.encode(0.25)
		local ok, value = Schema.decode(def, kind, b, n, s)
		expect(ok).toBe(true)
		expect(value).toBe(0.25)
		expect(Schema.decode(def, "choice", false, 0, "0.25")).toBe(false)
		expect(Schema.decode(def, "slider", false, math.huge, "")).toBe(false)
	end)
	it("cleans malformed saved structures without inventing schema authority", function()
		local clean =
			Schema.sanitize({ values = { good = false, other = 0.5, text = "a", nan = 0 / 0, bad = {} } })
		expect(clean.values.good).toBe(false)
		expect(clean.values.other).toBe(0.5)
		expect(clean.values.nan).toBe(nil)
		expect(clean.values.bad).toBe(nil)
	end)
end)
