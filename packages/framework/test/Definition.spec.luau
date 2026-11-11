--!nocheck
-- defineModule (module-api.md §2), Resolve (§3 step 1), Schema/ConfigValidate (§11), Semver.
local StudWork = require(script.Parent.Parent.shared)
local Resolve = require(script.Parent.Parent.shared.Resolve)
local Schema = require(script.Parent.Parent.shared.Schema)
local Semver = require(script.Parent.Parent.shared.Semver)
local ConfigValidate = require(script.Parent.Parent.shared.ConfigValidate)

local def = StudWork.defineModule

local function mod(name, extra)
	local spec = { name = name, version = "1.0.0", framework = "^1.3.0" }
	for k, v in extra or {} do
		spec[k] = v
	end
	return def(spec)
end

local function errOf(fn)
	local ok, err = pcall(fn)
	assert(not ok, "expected an error")
	return tostring(err)
end

describe("defineModule", function()
	it("returns a frozen ModuleRef with defaults filled", function()
		local A = mod("Alpha")
		expect(StudWork.isModuleRef(A)).toBe(true)
		expect(table.isfrozen(A)).toBe(true)
		expect(A.server).toBe("Alpha")
		expect(#A.dependsOn).toBe(0)
		expect(function()
			A.name = "x"
		end).toThrow()
	end)

	it("keeps dependency references by identity", function()
		local A = mod("Alpha")
		local B = mod("Beta", { dependsOn = { A } })
		expect(B.dependsOn[1]).toBe(A)
	end)

	it("collects every problem in one error", function()
		local msg = errOf(function()
			def({ name = "lower", version = "1", framework = "1.3", bogus = 1, dependsOn = { "Economy" } })
		end)
		expect(msg).toContain("name must be a PascalCase")
		expect(msg).toContain("version must be a semver")
		expect(msg).toContain("framework must be a semver range")
		expect(msg).toContain("bogus: unknown field")
		expect(msg).toContain('dependsOn[1] is the string "Economy"')
	end)

	it("rejects a non-ref dependency table", function()
		expect(function()
			mod("Beta", { optional = { { name = "Fake" } } })
		end).toThrow("optional[1] is not a ModuleRef")
	end)

	it("rejects data.replicate = true and checks replicate fields exist", function()
		expect(function()
			mod("A", { data = { key = "a", version = 1, default = { x = 1 }, replicate = true } })
		end).toThrow("data.replicate = true is not supported")
		expect(function()
			mod("A", { data = { key = "a", version = 1, default = { x = 1 }, replicate = { "y" } } })
		end).toThrow("'y' is not a field of data.default")
		local ok = mod("A", { data = { key = "a", version = 1, default = { x = 1 }, replicate = { "x" } } })
		expect(ok.data.replicate[1]).toBe("x")
		expect(
			mod("B", { data = { key = "b", version = 1, default = {}, replicate = false } }).data.replicate
		).toBe(false)
	end)

	it("validates the data block", function()
		local msg = errOf(function()
			mod("A", {
				data = {
					key = "_framework",
					version = 0,
					default = 5,
					sanitize = "no",
					adopts = "lower",
					migrations = { [1] = 1 },
					extra = true,
				},
			})
		end)
		expect(msg).toContain("reserved")
		expect(msg).toContain("data.version must be an integer >= 1")
		expect(msg).toContain("data.default must be a plain table")
		expect(msg).toContain("data.sanitize must be a function")
		expect(msg).toContain("data.adopts must be")
		expect(msg).toContain("data.migrations[1] must be a function")
		expect(msg).toContain("data.extra: unknown field")
	end)

	it("validates config schema and defaults", function()
		local msg = errOf(function()
			mod("A", {
				config = {
					schema = { a = "number", b = "nope", c = "number(0..1)" },
					defaults = { a = "x", z = 1, c = 2 },
				},
			})
		end)
		expect(msg).toContain("config.schema.b: unknown type 'nope'")
		expect(msg).toContain("config.defaults.a: expected number")
		expect(msg).toContain("config.defaults.z: no such key")
		expect(msg).toContain("config.defaults.c: expected number(0..1)")
	end)

	it("validates itemFields and theme shapes", function()
		local msg = errOf(function()
			mod("A", {
				itemFields = { item = { name = { x = "number" }, econ = { y = "bad" } }, other = {} },
				theme = { colors = { a = "red" }, nope = {} },
			})
		end)
		expect(msg).toContain("'name' is a base ItemDef field")
		expect(msg).toContain("itemFields.item.econ.y: unknown type 'bad'")
		expect(msg).toContain("itemFields.other: unknown kind")
		expect(msg).toContain("theme.colors.a must be '#RRGGBB'")
		expect(msg).toContain("theme.nope: unknown token group")
	end)
end)

describe("Resolve", function()
	it("topo-sorts on hard deps, breaking ties by list order", function()
		local A = mod("Alpha")
		local B = mod("Beta", { dependsOn = { A } })
		local C = mod("Gamma")
		local order = Resolve.resolve({ B, C, A }, "1.3.0")
		local names = {}
		for _, r in order do
			table.insert(names, r.name)
		end
		expect(table.concat(names, ",")).toBe("Gamma,Alpha,Beta")
	end)

	it("requires hard deps to be listed (no auto-enable) and collects all errors", function()
		local A = mod("Alpha")
		local B = mod("Beta", { dependsOn = { A } })
		local A2 = mod("Alpha")
		local _, errs = Resolve.resolve({ B, B, "Economy", A2, {} }, "1.3.0")
		local all = table.concat(errs, "\n")
		expect(all).toContain("'Beta' listed twice")
		expect(all).toContain('modules[3] is the string "Economy"')
		expect(all).toContain("modules[5] is not a ModuleRef")
		expect(all).toContain("depends on a different copy of 'Alpha'")
		local _, errs2 = Resolve.resolve({ B }, "1.3.0")
		expect(errs2[1]).toBe("module 'Beta' requires 'Alpha': add Alpha to GameConfig.modules")
	end)

	it("rejects duplicate names, duplicate data keys and incompatible framework ranges", function()
		local A = mod("Alpha", { data = { key = "shared", version = 1, default = {} } })
		local B = mod("Beta", { data = { key = "shared", version = 1, default = {} } })
		local A2 = mod("Alpha")
		local Old = def({ name = "Old", version = "1.0.0", framework = "^1.2.0" })
		local Next = def({ name = "Next", version = "1.0.0", framework = "^2.0.0" })
		local _, errs = Resolve.resolve({ A, B, A2, Old, Next }, "1.3.0")
		local all = table.concat(errs, "\n")
		expect(all).toContain("data.key 'shared' is declared by both 'Alpha' and 'Beta'")
		expect(all).toContain("two different modules are named 'Alpha'")
		expect(all).toContain("module 'Next' 1.0.0 needs framework ^2.0.0")
		expect(all).Not.toContain("'Old'") -- ^1.2.0 accepts 1.3.0
	end)

	it("names a dependency cycle", function()
		-- defineModule refs can't form a cycle (a definition only references existing ones), so
		-- hand-built manifests exercise this path.
		local a = { name = "A", framework = "*", dependsOn = {} }
		local b = { name = "B", framework = "*", dependsOn = { a } }
		local c = { name = "C", framework = "*", dependsOn = { b } }
		table.insert(a.dependsOn, c)
		local _, errs = Resolve.resolve({ a, b, c }, "1.3.0", function()
			return true
		end)
		expect(errs[1]).toBe("dependency cycle: A -> C -> B -> A")
	end)
end)

describe("Schema", function()
	it("parses the type-string language", function()
		for _, s in
			{
				"number",
				"integer?",
				"{string}",
				"{[string]: number}",
				'"a"|"b"',
				"enum(a,b)",
				"number(0..1)",
				"integer(1..)",
				"{ {number} }?",
			}
		do
			local node, err = Schema.parse(s)
			assert(node, s .. ": " .. tostring(err))
		end
		expect(select(2, Schema.parse("wat"))).toBe("unknown type 'wat'")
	end)

	it("validates values and collects every error, unknown keys as warnings", function()
		local errors, warnings = {}, {}
		Schema.validate({
			tick = "number(0..)",
			mode = '"multiply"|"add"',
			tags = "{string}",
			rates = "{[string]: number}",
			opt = "boolean?",
			nested = { depth = "integer" },
			described = { type = "string", description = "a described key" },
		}, {
			tick = -1,
			mode = "sum",
			tags = { "a", 2 },
			rates = { x = "1" },
			typo = 1,
			nested = { depth = 1.5 },
		}, "config.X", errors, warnings)
		local all = table.concat(errors, "\n")
		expect(all).toContain("config.X.tick")
		expect(all).toContain("config.X.mode: expected one of multiply, add")
		expect(all).toContain("config.X.tags[2]")
		expect(all).toContain("config.X.rates.x")
		expect(all).toContain("config.X.nested.depth")
		expect(all).toContain("config.X.described: required string, missing")
		expect(#errors).toBe(6)
		expect(warnings[1]).toContain("config.X.typo: unknown key")
	end)
end)

describe("ConfigValidate", function()
	it("merges GameConfig.config.<Name> over defaults and freezes it", function()
		local A = mod("Alpha", {
			config = {
				schema = { tick = "number", nested = { a = "number", b = "number" } },
				defaults = { tick = 1, nested = { a = 1, b = 2 } },
			},
		})
		local r = ConfigValidate.validate(
			{ A },
			{ gameId = "g", config = { Alpha = { nested = { b = 5 } } } }
		)
		expect(#r.errors).toBe(0)
		expect(r.configs.Alpha.tick).toBe(1)
		expect(r.configs.Alpha.nested.a).toBe(1)
		expect(r.configs.Alpha.nested.b).toBe(5)
		expect(table.isfrozen(r.configs.Alpha.nested)).toBe(true)
	end)

	it("reports all errors across modules together", function()
		local A = mod("Alpha", { config = { schema = { tick = "number" } } })
		local B = mod("Beta", { config = { schema = { name = "string" }, defaults = { name = "x" } } })
		local r = ConfigValidate.validate(
			{ A, B },
			{ gameId = "", config = { Beta = { name = 5 }, Gamma = {} }, bogus = 1 }
		)
		local all = table.concat(r.errors, "\n")
		expect(all).toContain("gameId must be")
		expect(all).toContain("config.Alpha.tick: required number, missing")
		expect(all).toContain("config.Beta.name: expected string")
		local warns = table.concat(r.warnings, "\n")
		expect(warns).toContain("config.Gamma: 'Gamma' is not enabled")
		expect(warns).toContain("GameConfig.bogus: unknown top-level key")
	end)
end)

describe("Semver", function()
	it("matches ranges", function()
		expect(Semver.satisfies("1.3.0", "^1.3.0")).toBe(true)
		expect(Semver.satisfies("1.4.2", "^1.3.0")).toBe(true)
		expect(Semver.satisfies("2.0.0", "^1.3.0")).toBe(false)
		expect(Semver.satisfies("1.2.9", "^1.3.0")).toBe(false)
		expect(Semver.satisfies("1.3.5", "~1.3.0")).toBe(true)
		expect(Semver.satisfies("1.4.0", "~1.3.0")).toBe(false)
		expect(Semver.satisfies("0.2.1", "^0.2.0")).toBe(true)
		expect(Semver.satisfies("0.3.0", "^0.2.0")).toBe(false)
		expect(Semver.satisfies("9.0.0", ">=1.3.0")).toBe(true)
		expect(Semver.satisfies("1.3.0", "1.3.0")).toBe(true)
	end)
end)
