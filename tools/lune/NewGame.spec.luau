--!nocheck
-- tools/ is outside the harness index (packages, games, templates), so load by file path.
local NewGame = require("tools/lune/NewGame.luau")
-- the kit module manifest, read from the kit module definitions (v1.3.0; was
-- the v1.2 module manifest)
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local Modules = require("tools/lune/KitModules.luau").load(fs, require("tools/lune/ModuleDiscovery.luau"))

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

	it("--into picks the parent folder (default games); only relative folders inside the project", function()
		expect(NewGame.parseArgs({ "gx" }).into).toBe("games")
		expect(NewGame.parseArgs({ "gx", "--into", "examples/overrides/" }).into).toBe("examples/overrides")
		for _, bad in { "/tmp", "../x", "a/../b", "--modules" } do
			local opts, err = NewGame.parseArgs({ "gx", "--into", bad })
			expect(opts).toBeNil()
			expect(type(err)).toBe("string")
		end
		local opts, err = NewGame.parseArgs({ "gx", "--into" })
		expect(opts).toBeNil()
		expect(type(err)).toBe("string")
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

-- v1.3.1 (R19): module refs are ReplicatedStorage.Modules.<Name>.module
local TEMPLATE_V13 = [[
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Unused = ReplicatedStorage:WaitForChild("Modules")

local Config = {
	gameId = "sandbox",
	modules = {
		require(Modules:WaitForChild("Items"):WaitForChild("module")), -- item definitions
		require(Modules:WaitForChild("Inventory"):WaitForChild("module")), -- owned copies (needs Items)
		require(Modules:WaitForChild("Economy"):WaitForChild("module")), -- currencies
		require(Modules:WaitForChild("Plot"):WaitForChild("module")), -- needs Inventory
	} :: { any },
}
]]

describe("NewGame v1.3 module refs", function()
	it("the kit manifest comes from the kit definitions (hard deps from dependsOn)", function()
		expect(Modules.isModule("Plot")).toBe(true)
		expect(Modules.SPECS.Plot.requires).toEqual({ "Inventory" })
		expect(Modules.SPECS.Upgrades.requires).toEqual({ "Economy" })
		expect(Modules.kitFolder("Mail")).toBe("Social")
		expect(Modules.ACTIONS.roll).toBe("Rarity")
		expect(Modules.ACTIONS.claimMail).toBe("Mail")
		expect(Modules.isModule("Codes")).toBe(true)
		expect(Modules.SPECS.Codes.requires).toEqual({})
		expect(Modules.SPECS.Settings.requires).toEqual({})
		expect(Modules.kitFolder("Codes")).toBe("Player")
		expect(Modules.kitFolder("Settings")).toBe("Player")
		expect(Modules.isModule("Companions")).toBe(true)
		expect(Modules.SPECS.Companions.requires).toEqual({ "Items", "Inventory" })
		-- the 15 template modules in KitModules.ORDER, then kit modules the template doesn't list
		-- yet, alphabetically
		expect(#Modules.ORDER).toBe(25)
		expect(Modules.ORDER[15]).toBe("Plot")
		expect(table.move(Modules.ORDER, 16, 25, 1, {})).toEqual({
			"Admin",
			"Carry",
			"Codes",
			"Companions",
			"Goals",
			"Moderation",
			"Movement",
			"Quests",
			"Reports",
			"Settings",
		})
	end)

	it("keeps the ref lines of chosen modules and adds a ref line for a missing one", function()
		local out = NewGame.rewriteModulesBlock(TEMPLATE_V13, { "Items", "Economy", "Mail" })
		expect(
			string.find(
				out,
				'require(Modules:WaitForChild("Items"):WaitForChild("module")), -- item definitions',
				1,
				true
			) ~= nil
		).toBe(true)
		expect(string.find(out, 'WaitForChild("Inventory")', 1, true)).toBeNil()
		expect(string.find(out, 'WaitForChild("Plot")', 1, true)).toBeNil()
		expect(
			string.find(out, '\t\trequire(Modules:WaitForChild("Mail"):WaitForChild("module")),', 1, true)
				~= nil
		).toBe(true)
		expect(string.find(out, "} :: { any },", 1, true) ~= nil).toBe(true)
	end)

	it("pruneKitLocals drops kit folder locals nothing uses any more", function()
		local out = NewGame.rewriteModulesBlock(TEMPLATE_V13, { "Items", "Inventory" })
		out = NewGame.pruneKitLocals(out)
		expect(string.find(out, "local Unused =", 1, true)).toBeNil()
		expect(string.find(out, 'WaitForChild("Economy")', 1, true)).toBeNil()
		expect(string.find(out, 'WaitForChild("Plot")', 1, true)).toBeNil()
		expect(string.find(out, 'local Modules = ReplicatedStorage:WaitForChild("Modules")', 1, true) ~= nil).toBe(
			true
		)
	end)

	it("trimDependsOn drops refs of modules not chosen and adds none", function()
		local src = [[
return StudWork.defineModule({
	name = "Sandbox",
	dependsOn = {
		require(Collection:WaitForChild("Rarity")),
		require(EconomyKit:WaitForChild("Rebirth")),
	},
})
]]
		local out = NewGame.trimDependsOn(src, { "Items", "Rarity", "Mail" })
		expect(string.find(out, 'WaitForChild("Rarity")', 1, true) ~= nil).toBe(true)
		expect(string.find(out, 'WaitForChild("Rebirth")', 1, true)).toBeNil()
		expect(string.find(out, "Mail", 1, true)).toBeNil()
	end)

	it("trimDependsOn trims an optional block the same way (v1.7.0)", function()
		local src = [[
return StudWork.defineModule({
	name = "Sandbox",
	dependsOn = {
		require(Collection:WaitForChild("Rarity")),
	},
	optional = {
		require(KitDefs:WaitForChild("Leaderboards"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Badges"):WaitForChild("module")),
	},
})
]]
		local out = NewGame.trimDependsOn(src, { "Rarity", "Badges" })
		expect(string.find(out, 'WaitForChild("Badges")', 1, true) ~= nil).toBe(true)
		expect(string.find(out, "Leaderboards", 1, true)).toBeNil()
		local none = NewGame.trimDependsOn(src, { "Rarity" })
		expect(string.find(none, "optional = {}", 1, true) ~= nil).toBe(true)
	end)

	it("moduleName makes the game module's name from the gameId", function()
		expect(NewGame.moduleName("example-collector")).toBe("ExampleCollector")
		expect(NewGame.moduleName("zz-scratch")).toBe("ZzScratch")
		expect(NewGame.moduleName("sandbox")).toBe("Sandbox")
	end)

	it("renameConsolePrefix turns the template's console prefix and log tag into the module's", function()
		local src = 'help = "sandbox giftme [itemId]: x", tag = "[sandbox] hi", Sandbox = {}, "SandboxWorld"'
		local out = NewGame.renameConsolePrefix(src, "MyGame")
		expect(out).toBe(
			'help = "mygame giftme [itemId]: x", tag = "[mygame] hi", Sandbox = {}, "SandboxWorld"'
		)
	end)

	it("the template's server part has no other lower-case `sandbox` than the prefix and tag", function()
		local text = fs.readFile("templates/new-game/modules/sandbox/server/init.luau")
		for line in string.gmatch(text, "[^\n]+") do
			if string.find(line, "%f[%w]sandbox%f[%W]") then
				local ok = string.find(line, "Invoke(", 1, true)
					or string.find(line, "[sandbox]", 1, true)
					or string.find(line, '"sandbox ', 1, true)
				expect(ok ~= nil).toBe(true)
			end
		end
	end)

	it("--help and -h are recognised anywhere, and the help carries the usage", function()
		expect(NewGame.wantsHelp({ "--help" })).toBe(true)
		expect(NewGame.wantsHelp({ "game", "-h" })).toBe(true)
		expect(NewGame.wantsHelp({ "game", "--modules", "Items" })).toBe(false)
		expect(NewGame.HELP).toContain(NewGame.USAGE)
		expect(NewGame.HELP).toContain("--into")
	end)
end)

describe("NewGame.applyMarkers (tools/new-game --modules)", function()
	local function set(list: { string }): { [string]: boolean }
		local s = {}
		for _, n in list do
			s[n] = true
		end
		return s
	end

	local SRC = table.concat({
		"local a = 1",
		"local econ = 2 -- @if Economy",
		"-- @if Rarity,Inventory",
		"local both = 3",
		"-- @if Economy",
		"local nested = 4",
		"-- @end",
		"-- @else",
		"local neither = 5",
		"-- @end",
		"-- @if Mail|Friends",
		"local social = 6",
		"-- @end",
		'\tsource = "displayed", -- @if Plot',
		'\t-- @unless Plot: source = "owned",',
		"local z = 7",
	}, "\n")

	it("keeps chosen blocks and lines, drops the rest, and strips every marker", function()
		local out = assert(NewGame.applyMarkers(SRC, set({ "Rarity", "Inventory", "Economy", "Plot" })))
		expect(out).toBe(table.concat({
			"local a = 1",
			"local econ = 2",
			"local both = 3",
			"local nested = 4",
			'\tsource = "displayed",',
			"local z = 7",
		}, "\n"))
	end)

	it("takes @else, any-of (|) and @unless replacements when modules are left out", function()
		local out = assert(NewGame.applyMarkers(SRC, set({ "Friends" })))
		expect(out).toBe(table.concat({
			"local a = 1",
			"local neither = 5",
			"local social = 6",
			'\tsource = "owned",',
			"local z = 7",
		}, "\n"))
	end)

	it("a nested block inside a dropped block stays dropped", function()
		local out = assert(NewGame.applyMarkers(SRC, set({ "Economy" })))
		expect(string.find(out, "nested", 1, true)).toBeNil()
		expect(string.find(out, "neither", 1, true) ~= nil).toBe(true)
	end)

	it("alternatives of all-of groups: A,B|C", function()
		local src = "x -- @if Economy,Rebirth|Upgrades"
		expect(NewGame.applyMarkers(src, set({ "Economy" }))).toBe("")
		expect(NewGame.applyMarkers(src, set({ "Economy", "Rebirth" }))).toBe("x")
		expect(NewGame.applyMarkers(src, set({ "Upgrades" }))).toBe("x")
	end)

	it("reports unbalanced or unknown markers with the line number", function()
		for src, needle in
			{
				["-- @if Economy\nx"] = "line 1: @if without @end",
				["x\n-- @end"] = "line 2: @end without",
				["-- @else"] = "line 1: @else without",
				["-- @if A\n-- @else\n-- @else\n-- @end"] = "line 3: @else without",
				["-- @frob"] = "line 1: unknown marker",
			}
		do
			local out, err = NewGame.applyMarkers(src, {})
			expect(out).toBeNil()
			expect(string.find(tostring(err), needle, 1, true) ~= nil).toBe(true)
		end
	end)

	it("markerNames lists every module a marker mentions", function()
		expect(NewGame.markerNames(SRC)).toEqual({
			"Economy",
			"Friends",
			"Inventory",
			"Mail",
			"Plot",
			"Rarity",
		})
	end)

	it("pruneKitLocals also drops unused kit requires, the Kits folder and services, until stable", function()
		local src = table.concat({
			'local ReplicatedStorage = game:GetService("ReplicatedStorage")',
			'local Players = game:GetService("Players")',
			'local Modules = ReplicatedStorage:WaitForChild("Modules")',
			'local Rarity = require(Modules:WaitForChild("Rarity"):WaitForChild("module")) -- Rarity is mentioned here only',
			"print(Players)",
		}, "\n")
		expect(NewGame.pruneKitLocals(src)).toBe('local Players = game:GetService("Players")\nprint(Players)')
	end)
end)

describe("templates/new-game module markers", function()
	local files = {}
	local function walk(dir: string)
		for _, entry in fs.readDir(dir) do
			local path = dir .. "/" .. entry
			if fs.isDir(path) then
				walk(path)
			elseif string.match(entry, "%.luau$") then
				files[path] = fs.readFile(path)
			end
		end
	end
	walk("templates/new-game")

	it("only name real kit modules", function()
		for path, source in files do
			for _, n in NewGame.markerNames(source) do
				expect(Modules.isModule(n) and n or (path .. ": unknown module '" .. n .. "' in a marker")).toBe(
					n
				)
			end
		end
	end)

	it("resolve for every module, for none and for each single module, leaving no marker behind", function()
		local subsets = { Modules.ORDER, {} }
		for _, n in Modules.ORDER do
			table.insert(subsets, { n })
		end
		local luau = (getmetatable(getfenv(1)) :: any).__index.require("@lune/luau")
		for _, subset in subsets do
			local chosen = {}
			for _, n in subset do
				chosen[n] = true
			end
			for path, source in files do
				local out, err = NewGame.applyMarkers(source, chosen)
				if out == nil then
					error(path .. ": " .. tostring(err))
				end
				expect(string.find(out, "-- @", 1, true) == nil and path or (path .. " still has a marker")).toBe(
					path
				)
				local ok, compileErr = pcall(luau.compile, out)
				if not ok then
					error(
						path
							.. " with {"
							.. table.concat(subset, ",")
							.. "} does not compile: "
							.. tostring(compileErr)
					)
				end
			end
		end
	end)
end)
