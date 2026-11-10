--!nocheck
-- tools/ is outside the harness index (packages, games, templates), so load by file path.
local NewGame = require("tools/lune/NewGame.luau")
local Modules = require("packages/core/shared/Modules.luau")

local TEMPLATE_CONFIG = [[
local Config = {
	gameId = "sandbox",
	-- comment above the list
	modules = {
		"Items", -- item definitions
		"Inventory", -- owned copies (needs Items)
		"Economy", -- currencies
		"Upgrades", -- needs Economy
		"Plot", -- needs Inventory
	},
	other = { "x" },
}
]]

describe("NewGame.parseArgs", function()
	it("parses name only (defaults: template modules, design doc)", function()
		local opts = NewGame.parseArgs({ "example-shop" })
		expect(opts.name).toBe("example-shop")
		expect(opts.modules).toBeNil()
		expect(opts.designDoc).toBe(true)
	end)

	it("parses --modules (both forms, trims spaces) and --no-design-doc in any order", function()
		local a = NewGame.parseArgs({ "--no-design-doc", "g1", "--modules", "Items, Economy" })
		expect(a.name).toBe("g1")
		expect(a.modules).toEqual({ "Items", "Economy" })
		expect(a.designDoc).toBe(false)
		local b = NewGame.parseArgs({ "g2", "--modules=Mail" })
		expect(b.modules).toEqual({ "Mail" })
	end)

	it("--modules with an empty list means foundation only", function()
		local opts = NewGame.parseArgs({ "gx", "--modules", "," })
		expect(opts.modules).toEqual({})
	end)

	it("rejects bad names, unknown options, missing values and extra args", function()
		for _, args in
			{
				{},
				{ "Bad_Name" },
				{ "x" },
				{ "gx", "--frobnicate" },
				{ "gx", "--modules" },
				{ "gx", "--modules", "--no-design-doc" },
				{ "gx", "h" },
			}
		do
			local opts, err = NewGame.parseArgs(args)
			expect(opts).toBeNil()
			expect(type(err)).toBe("string")
		end
	end)
end)

describe("NewGame.resolveModules", function()
	it("returns boot order and adds missing hard dependencies transitively", function()
		local order, added = NewGame.resolveModules(Modules, { "Plot", "Upgrades" })
		expect(order).toEqual({ "Items", "Inventory", "Economy", "Upgrades", "Plot" })
		expect(added).toContain("Inventory (required by Plot)")
		expect(added).toContain("Economy (required by Upgrades)")
		expect(added).toContain("Items (required by Inventory)")
	end)

	it("adds nothing when dependencies are listed", function()
		local order, added = NewGame.resolveModules(Modules, { "Economy", "Items", "Mail" })
		expect(order).toEqual({ "Items", "Economy", "Mail" })
		expect(#added).toBe(0)
	end)

	it("rejects unknown, foundation and duplicate names (all reported)", function()
		local order, _, errors = NewGame.resolveModules(Modules, { "Itemz", "Data", "Mail", "Mail" })
		expect(order).toBeNil()
		expect(#errors).toBe(3)
		expect(string.find(errors[1], "unknown module 'Itemz'", 1, true) ~= nil).toBe(true)
		expect(string.find(errors[2], "foundation", 1, true) ~= nil).toBe(true)
		expect(string.find(errors[3], "listed twice", 1, true) ~= nil).toBe(true)
	end)

	it("an empty list is valid (foundation only)", function()
		local order = NewGame.resolveModules(Modules, {})
		expect(order).toEqual({})
	end)
end)

describe("NewGame.rewriteModulesBlock", function()
	it("keeps the template's commented lines of chosen modules only", function()
		local out = NewGame.rewriteModulesBlock(TEMPLATE_CONFIG, { "Items", "Economy" })
		expect(string.find(out, '"Items", -- item definitions', 1, true) ~= nil).toBe(true)
		expect(string.find(out, '"Economy", -- currencies', 1, true) ~= nil).toBe(true)
		expect(string.find(out, '"Inventory"', 1, true)).toBeNil()
		expect(string.find(out, '"Plot"', 1, true)).toBeNil()
		expect(string.find(out, 'other = { "x" }', 1, true) ~= nil).toBe(true)
		expect(string.find(out, "-- comment above the list", 1, true) ~= nil).toBe(true)
	end)

	it("the rewritten block parses back to exactly the chosen list", function()
		local out = NewGame.rewriteModulesBlock(TEMPLATE_CONFIG, { "Items", "Inventory", "Plot" })
		local body = string.match(out, "modules%s*=%s*(%b{})")
		local names = {}
		for n in string.gmatch(body, '"([%w_]+)"') do
			table.insert(names, n)
		end
		expect(names).toEqual({ "Items", "Inventory", "Plot" })
	end)

	it("adds a plain line for a module the template doesn't list", function()
		local out = NewGame.rewriteModulesBlock(TEMPLATE_CONFIG, { "Items", "Mail" })
		expect(string.find(out, '\t\t"Mail",', 1, true) ~= nil).toBe(true)
	end)

	it("writes modules = {} for foundation only", function()
		local out = NewGame.rewriteModulesBlock(TEMPLATE_CONFIG, {})
		expect(string.find(out, "modules = {},", 1, true) ~= nil).toBe(true)
	end)

	it("errors when the Config has no modules block", function()
		local out, err = NewGame.rewriteModulesBlock("return {}", { "Items" })
		expect(out).toBeNil()
		expect(type(err)).toBe("string")
	end)
end)

describe("NewGame.deployJson / readme", function()
	it("deploy.json has placeholder ids that tools/publish refuses, and a note saying so", function()
		local PublishGate = require("tools/lune/PublishGate.luau")
		local d = NewGame.deployJson("g", 34900)
		expect(d.servePort).toBe(34900)
		expect(PublishGate.isPlaceholderId(d.test.placeId)).toBe(true)
		expect(PublishGate.isPlaceholderId(d.live.universeId)).toBe(true)
		expect(string.find(d.idsNote, "PLACEHOLDER", 1, true) ~= nil).toBe(true)
		local decision = PublishGate.decide({
			target = "test",
			dryRun = false,
			deploy = d,
			head = "h",
			dirty = {},
			keyPresent = true,
		})
		expect(decision.ok).toBe(false)
	end)

	it("README has a 'Status: scaffolded' line and reflects options", function()
		local r = NewGame.readme("g", 34900, false, { "Items" })
		expect(string.find(r, "\nStatus: scaffolded\n", 1, true) ~= nil).toBe(true)
		expect(string.find(r, "--no-design-doc", 1, true) ~= nil).toBe(true)
		expect(string.find(r, "Modules: Items", 1, true) ~= nil).toBe(true)
		local r2 = NewGame.readme("g", 34900, true, nil)
		expect(string.find(r2, "docs/games/g.md", 1, true) ~= nil).toBe(true)
		expect(string.find(r2, "template default", 1, true) ~= nil).toBe(true)
	end)
end)
