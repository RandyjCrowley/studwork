--!nocheck
-- tools/lune/AdoptInit (StudWork v1.6.0, docs/framework/adopting.md §2): the pure parts of
-- `tools/adopt --init`: arguments, the project-file merge (clash, key order, idempotence), the
-- legacy list and baseline from the guardrails' findings, studwork.json, path containment.
local AdoptInit = require("tools/lune/AdoptInit.luau")
local SyncProjects = require("tools/lune/SyncProjects.luau")
local NewGame = require("tools/lune/NewGame.luau")
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")

local function parse(args)
	return AdoptInit.parseArgs(args, NewGame.validName)
end

local LEGACY_PROJECT = [[
{
	"name": "legacy-example-a",
	"servePort": 34999,
	"tree": {
		"$className": "DataModel",
		"ServerScriptService": {
			"Server": { "$path": "src/server" }
		},
		"ReplicatedStorage": {
			"Shared": { "$path": "src/shared" }
		},
		"Workspace": { "$properties": { "StreamingEnabled": true } }
	}
}
]]

describe("AdoptInit.parseArgs", function()
	it("defaults: id from the folder, the public url, install on, no dry run", function()
		local opts = parse({ "../games/legacy-example-a/" })
		expect(opts.path).toBe("../games/legacy-example-a/")
		expect(opts.name).toBe("legacy-example-a")
		expect(opts.url).toBe(AdoptInit.DEFAULT_URL)
		expect(opts.tag).toBeNil()
		expect(opts.modules).toBeNil()
		expect(opts.dryRun).toBe(false)
		expect(opts.install).toBe(true)
	end)

	it("reads every option", function()
		local opts = parse({
			"proj",
			"--name=my-game",
			"--modules",
			"Items, Inventory",
			"--tag",
			"v1.6.0",
			"--url",
			"../studwork",
			"--dry-run",
			"--no-install",
		})
		expect(opts.name).toBe("my-game")
		expect(opts.modules).toEqual({ "Items", "Inventory" })
		expect(opts.tag).toBe("v1.6.0")
		expect(opts.url).toBe("../studwork")
		expect(opts.dryRun).toBe(true)
		expect(opts.install).toBe(false)
	end)

	it("refuses bad input", function()
		local _, e1 = parse({})
		expect(e1).toContain("usage: tools/adopt --init")
		local _, e2 = parse({ "Bad_Name" })
		expect(e2).toContain("bad game id")
		expect(e2).toContain("--name")
		local _, e3 = parse({ "proj", "--tag", "1.6" })
		expect(e3).toContain("--tag must be a release tag")
		local _, e4 = parse({ "proj", "--commit" })
		expect(e4).toContain("unknown option --commit")
		local _, e5 = parse({ "proj", "--name" })
		expect(e5).toContain("--name needs a value")
		local _, e6 = parse({ "a", "b" })
		expect(e6).toContain("unexpected argument b")
		local _, e7 = parse({ "proj", "--name", "my-game", "--name", "x-game" })
		expect(e7).toContain("given twice")
	end)
end)

describe("AdoptInit.findProjectFile", function()
	it("prefers default.project.json, else the only project file", function()
		expect(AdoptInit.findProjectFile({ "a.project.json", "default.project.json" })).toBe(
			"default.project.json"
		)
		expect(AdoptInit.findProjectFile({ "src", "place.project.json" })).toBe("place.project.json")
		local none, e1 = AdoptInit.findProjectFile({ "src" })
		expect(none).toBeNil()
		expect(e1).toContain("--from-place")
		local many, e2 = AdoptInit.findProjectFile({ "a.project.json", "b.project.json" })
		expect(many).toBeNil()
		expect(e2).toContain("a.project.json, b.project.json")
	end)
end)

describe("AdoptInit.isSafeRel", function()
	it("accepts paths inside the project only", function()
		expect(AdoptInit.isSafeRel("modules/my-game/module.luau")).toBe(true)
		expect(AdoptInit.isSafeRel(".githooks/pre-commit")).toBe(true)
		expect(AdoptInit.isSafeRel("/etc/passwd")).toBe(false)
		expect(AdoptInit.isSafeRel("../outside")).toBe(false)
		expect(AdoptInit.isSafeRel("modules/../../x")).toBe(false)
		expect(AdoptInit.isSafeRel("./x")).toBe(false)
		expect(AdoptInit.isSafeRel("a//b")).toBe(false)
		expect(AdoptInit.isSafeRel("")).toBe(false)
		expect(AdoptInit.isSafeRel("a\\..\\b")).toBe(false)
	end)
end)

describe("AdoptInit.mergeProject", function()
	it(
		"adds children to a service mapped with $path (Rojo merges them), unless that folder has the name",
		function()
			local text = [[{ "name": "g", "tree": { "$className": "DataModel",
			"ServerScriptService": { "$path": "src/server" }, "ReplicatedStorage": { "$path": "src/shared" } } }]]
			local none = AdoptInit.mergeProject(SyncProjects, text, "my-game", function()
				return false
			end)
			expect(none).never.toBeNil()
			local tree = SyncProjects.decode(none).vals.tree
			expect(tree.vals.ServerScriptService.vals["$path"]).toBe("src/server")
			expect(tree.vals.ServerScriptService.vals.Framework.vals["$path"]).toBe(
				"studwork/packages/framework/server"
			)
			local again = AdoptInit.mergeProject(SyncProjects, none, "my-game", function()
				return false
			end)
			expect(again).toBe(none)
			local out, _, clashes = AdoptInit.mergeProject(SyncProjects, text, "my-game", function(path, name)
				return path == "src/shared" and name == "Modules"
			end)
			expect(out).toBeNil()
			expect(clashes[1]).toContain("ReplicatedStorage.Modules")
			-- without the folder check (pure callers) it stays a clash
			local _, _, plain = AdoptInit.mergeProject(SyncProjects, text, "my-game")
			expect(#plain > 0).toBe(true)
		end
	)

	it("adds the StudWork entries after the existing ones, keeping their order and values", function()
		local out, added, clashes = AdoptInit.mergeProject(SyncProjects, LEGACY_PROJECT, "legacy-example-a")
		expect(clashes).toEqual({})
		expect(out).never.toBeNil()
		local project = SyncProjects.decode(out)
		expect(project.keys).toEqual({ "name", "servePort", "tree", "globIgnorePaths" })
		expect(project.vals.servePort).toBe(34999)
		local tree = project.vals.tree
		expect(tree.keys).toEqual({
			"$className",
			"ServerScriptService",
			"ReplicatedStorage",
			"Workspace",
			"ReplicatedFirst",
			"ServerStorage",
		})
		local rs = tree.vals.ReplicatedStorage
		expect(rs.keys).toEqual({
			"Shared",
			"Packages",
			"FrameworkClient",
			"Framework",
			"UI",
			"GameModule",
			"Modules",
			"Game",
		})
		expect(rs.vals.Game.vals.Config.vals["$path"]).toBe("src/shared/Config")
		expect(tree.vals.ReplicatedFirst.vals.StudWorkBoot.vals["$path"]).toBe("studwork-boot/client")
		expect(rs.vals.Shared.vals["$path"]).toBe("src/shared")
		expect(rs.vals.Framework.vals["$path"]).toBe("studwork/packages/framework/shared")
		expect(rs.vals.GameModule.vals.module.vals["$path"]).toBe("modules/legacy-example-a/module.luau")
		local sss = tree.vals.ServerScriptService
		expect(sss.keys).toEqual({ "Server", "Framework", "Modules", "StudWorkBoot" })
		expect(sss.vals.Modules.vals.LegacyExampleA.vals["$path"]).toBe("modules/legacy-example-a/server")
		expect(tree.vals.ServerStorage.vals.ServerPackages.vals["$path"]).toBe("studwork/deps/ServerPackages")
		expect(tree.vals.Workspace.vals["$properties"].vals.StreamingEnabled).toBe(true)
		expect(table.find(added, "ReplicatedStorage.Framework")).never.toBeNil()
		expect(table.find(project.vals.globIgnorePaths.items, "**/*.spec.luau")).never.toBeNil()
		-- no absolute path, nothing leaves the project
		expect(string.find(out, '"/', 1, true)).toBeNil()
		expect(string.find(out, '"../', 1, true)).toBeNil()
	end)

	it("is idempotent, also after tools/sync-projects added the kit entries", function()
		local once = AdoptInit.mergeProject(SyncProjects, LEGACY_PROJECT, "legacy-example-a")
		local twice, added = AdoptInit.mergeProject(SyncProjects, once, "legacy-example-a")
		expect(twice).toBe(once)
		expect(added).toEqual({})
		-- what sync-projects writes (a kit holder under RS.Modules, its server part under SSS.Modules)
		local project = SyncProjects.decode(once)
		local holder = SyncProjects.newObject()
		SyncProjects.set(holder, "$className", "Folder")
		local m = SyncProjects.newObject()
		SyncProjects.set(m, "$path", "studwork/packages/kits/economy/Economy/module.luau")
		SyncProjects.set(holder, "module", m)
		SyncProjects.set(project.vals.tree.vals.ReplicatedStorage.vals.Modules, "Economy", holder)
		local s = SyncProjects.newObject()
		SyncProjects.set(s, "$path", "studwork/packages/kits/economy/Economy/server")
		SyncProjects.set(project.vals.tree.vals.ServerScriptService.vals.Modules, "Economy", s)
		local synced = SyncProjects.encode(project)
		local again, _, clashes = AdoptInit.mergeProject(SyncProjects, synced, "legacy-example-a")
		expect(clashes).toEqual({})
		expect(again).toBe(synced)
	end)

	it("stops on every clash and returns no text", function()
		local text = [[
{
	"name": "x",
	"tree": {
		"$className": "DataModel",
		"ReplicatedStorage": {
			"Packages": { "$path": "Packages" },
			"Modules": { "$path": "src/modules" },
			"UI": { "$path": "studwork/packages/ui" }
		},
		"ServerScriptService": { "Framework": { "$path": "src/framework" } }
	}
}
]]
		local out, added, clashes = AdoptInit.mergeProject(SyncProjects, text, "my-game")
		expect(out).toBeNil()
		expect(added).toEqual({})
		expect(clashes).toEqual({
			"ReplicatedStorage.Packages",
			"ReplicatedStorage.Modules",
			"ServerScriptService.Framework",
		})
	end)

	it("treats a service mapped with $path, or another game's module folder, as a clash", function()
		local text = [[
{ "name": "x", "tree": { "$className": "DataModel",
	"ReplicatedStorage": { "$path": "src/rs" },
	"ServerScriptService": { "Modules": { "$className": "Folder", "Other": { "$path": "modules/other-game/server" } } } } }
]]
		local out, _, clashes = AdoptInit.mergeProject(SyncProjects, text, "my-game")
		expect(out).toBeNil()
		expect(#clashes).toBe(2)
		expect(clashes[1]).toContain("ReplicatedStorage (mapped with")
		expect(clashes[2]).toBe("ServerScriptService.Modules")
	end)

	it("refuses a project file without a tree", function()
		local out, _, clashes = AdoptInit.mergeProject(SyncProjects, '{ "name": "x" }', "my-game")
		expect(out).toBeNil()
		expect(clashes[1]).toContain('"tree"')
	end)
end)

local FINDINGS = [[
== guardrails
./src/server/Save.server.luau:4: [purchases] DataStoreService outside framework Data
src/server/Save.server.luau:9: [purchases] DataStoreService outside framework Data
src/server/Shop.server.luau:3: [remotes] RemoteEvent/RemoteFunction in game code
src/server/Shop.server.luau:9: [remotes] OnServerEvent in game code
src/server/Shop.server.luau:7: [numbers] balance number in game code
src/server/Receipts.server.luau:2: [purchases] MarketplaceService.ProcessReceipt assigned outside the framework
staged: [packages] one commit edits the game and studwork/
guardrails: 6 finding(s)
]]

describe("AdoptInit legacy list and baseline", function()
	it("parses the guardrails' finding lines and nothing else", function()
		local f = AdoptInit.parseFindings(FINDINGS)
		expect(#f).toBe(6)
		expect(f[1]).toEqual({
			path = "src/server/Save.server.luau",
			line = 4,
			check = "purchases",
			message = "DataStoreService outside framework Data",
		})
	end)

	it("one entry per file with its checks; per-check counts in the baseline; generic reasons", function()
		local list, baseline, mustFix = AdoptInit.legacyList(AdoptInit.parseFindings(FINDINGS), nil)
		expect(#list.files).toBe(3)
		expect(list.files[1].path).toBe("src/server/Receipts.server.luau")
		expect(list.files[3]).toEqual({
			path = "src/server/Shop.server.luau",
			checks = { "numbers", "remotes" },
			reason = "existing code before StudWork: numbers, remotes",
		})
		expect(baseline.files["src/server/Save.server.luau"]).toEqual({ purchases = 2 })
		expect(baseline.files["src/server/Shop.server.luau"]).toEqual({ numbers = 1, remotes = 2 })
		expect(mustFix).toEqual({ "src/server/Receipts.server.luau" })
	end)

	it("takes reasons from the audit report", function()
		local report = {
			datastores = {
				{
					name = "PlayerSave",
					calls = { { op = "GetAsync", file = "src/server/Save.server.luau", line = 4 } },
				},
			},
			remotes = {
				{
					name = "Buy",
					handlers = { { kind = "OnServerEvent", file = "src/server/Shop.server.luau", line = 9 } },
				},
			},
		}
		local list = AdoptInit.legacyList(AdoptInit.parseFindings(FINDINGS), report)
		expect(list.files[2].reason).toContain("old save code (DataStore PlayerSave)")
		expect(list.files[3].reason).toContain("old remote handlers")
		expect(list.files[1].reason).toBe("existing code before StudWork: purchases")
	end)

	it("never downgraded: ProcessReceipt, special, packages", function()
		expect(AdoptInit.mustFix({ check = "special", message = "x" })).toBe(true)
		expect(AdoptInit.mustFix({ check = "packages", message = "x" })).toBe(true)
		expect(AdoptInit.mustFix({ check = "purchases", message = "ProcessReceipt assigned" })).toBe(true)
		expect(AdoptInit.mustFix({ check = "purchases", message = "DataStoreService" })).toBe(false)
		expect(AdoptInit.mustFix({ check = "remotes", message = "x" })).toBe(false)
	end)

	it("renders studwork.json and studwork-legacy.json in the pinned shape, stable", function()
		local list, baseline = AdoptInit.legacyList(AdoptInit.parseFindings(FINDINGS), nil)
		local text = AdoptInit.renderStudworkJson(SyncProjects, nil, baseline)
		local decoded = SyncProjects.decode(text)
		expect(decoded.keys).toEqual({ "layout", "framework", "adopted", "legacyBaseline" })
		expect(decoded.vals.layout).toBe("single-game")
		expect(decoded.vals.adopted).toBe(true)
		expect(decoded.vals.legacyBaseline.vals.files.keys).toEqual({
			"src/server/Receipts.server.luau",
			"src/server/Save.server.luau",
			"src/server/Shop.server.luau",
		})
		expect(AdoptInit.renderStudworkJson(SyncProjects, nil, baseline)).toBe(text)
		local withPlace = SyncProjects.decode(AdoptInit.renderStudworkJson(SyncProjects, "place.rbxl", nil))
		expect(withPlace.keys).toEqual({ "layout", "framework", "adopted", "placeFile", "legacyBaseline" })
		expect(withPlace.vals.legacyBaseline.vals.files.keys).toEqual({})
		local legacy = SyncProjects.decode(AdoptInit.renderLegacyJson(SyncProjects, list))
		local first = legacy.vals.files.items[1]
		expect(first.keys).toEqual({ "path", "checks", "reason" })
		expect(first.vals.checks.items).toEqual({ "purchases" })
	end)
end)

describe("AdoptInit.storeCollision", function()
	it("finds an old store named like StudWork's own", function()
		expect(AdoptInit.storeCollision(nil, "my-game")).toBeNil()
		expect(AdoptInit.storeCollision({ datastores = { { name = "PlayerData" } } }, "my-game")).toBeNil()
		expect(AdoptInit.storeCollision({ datastores = { { name = "PlayerData_my-game" } } }, "my-game")).toBe(
			"PlayerData_my-game"
		)
		expect(
			AdoptInit.storeCollision(
				{ libraries = { { name = "ProfileStore", store = "PlayerData_my-game_Studio" } } },
				"my-game"
			)
		).toBe("PlayerData_my-game_Studio")
	end)
end)

describe("AdoptInit helpers", function()
	it("merges .gitignore by appending only the missing lines, once", function()
		local template = "# header\n/.cache/\n/build/\n.env\n"
		local merged = AdoptInit.mergeGitignore("node_modules\n/build/", template)
		expect(merged).toBe("node_modules\n/build/\n\n# StudWork (tools/adopt --init)\n/.cache/\n.env\n")
		expect(AdoptInit.mergeGitignore(merged, template)).toBeNil()
		expect(AdoptInit.mergeGitignore(nil, template)).toBe(
			"# StudWork (tools/adopt --init)\n/.cache/\n/build/\n.env\n"
		)
	end)

	it("module name and dependsOn lines", function()
		expect(AdoptInit.moduleName("legacy-example-a")).toBe("LegacyExampleA")
		expect(AdoptInit.dependsOnLines({ "Items" })).toBe(
			'\t\trequire(KitDefs:WaitForChild("Items"):WaitForChild("module")),\n'
		)
		expect(AdoptInit.dependsOnLines({})).toBe("")
	end)

	it("lineDiff shows only the changed lines with context", function()
		local d = AdoptInit.lineDiff("a\nb\nc\nd\ne\nf\ng\n", "a\nb\nc\nX\ne\nf\ng\n")
		expect(d).toBe("@@\n b\n c\n-d\n+X\n e\n f\n@@")
		expect(AdoptInit.lineDiff("same\n", "same\n")).toBe("@@")
	end)

	it("templates/adopt has the game module templates with the stubbed legacy calls", function()
		for _, f in { "module.luau.tmpl", "server/init.luau.tmpl", "module.spec.luau.tmpl", "README.md.tmpl" } do
			expect(fs.isFile("templates/adopt/" .. f)).toBe(true)
		end
		local server = fs.readFile("templates/adopt/server/init.luau.tmpl")
		for _, call in { "importLegacy", "legacyReceipts", "onLegacyProduct" } do
			expect(server).toContain(
				"-- _ctx." .. (if call == "importLegacy" then "data." else "shop.") .. call
			)
		end
		expect(fs.readFile("templates/adopt/README.md.tmpl")).toContain(
			"| Old store | Old field | New home | Notes |"
		)
		expect(fs.readFile("templates/adopt/module.luau.tmpl")).toContain('key = "{{gameId}}"')
		for _, w in { "adopt", "test-migration" } do
			expect(fs.readFile("templates/single-game/tools/" .. w)).toContain('_studwork" ' .. w .. ' "$@"')
		end
	end)
end)

describe("AdoptInit (v1.6.0 dogfood r2)", function()
	local NewProject = require("tools/lune/NewProject.luau")
	local TEMPLATE = fs.readFile("templates/adopt/config/init.luau.tmpl")
	local REPORT = {
		purchases = {
			products = { { id = 5556 }, { id = 5555 }, { id = 5555 }, { id = "x" } },
			passes = { { id = 2222 } },
		},
	}

	it(
		"renders a minimal GameConfig: chosen modules at defaults, the audit's ids, no sandbox content",
		function()
			local text, err = AdoptInit.renderConfig(
				TEMPLATE,
				NewProject.render,
				"my-game",
				{ "Items", "Inventory", "Economy" },
				REPORT
			)
			expect(err).toBeNil()
			expect(text).toContain('gameId = "my-game"')
			expect(text).toContain('require(Modules:WaitForChild("Inventory"):WaitForChild("module")),')
			expect(text).toContain("-- Economy = {}, -- at its defaults")
			expect(text).toContain("compliance = { paidCurrencies = {} },")
			expect(text).toContain("items = {},")
			expect(text).toContain("events = {},")
			expect(text).toContain("Product5555 = 5555, -- TODO: name it")
			expect(text).toContain("Product5556 = 5556, -- TODO: name it")
			expect(text).toContain("Pass2222 = 2222, -- TODO: name it")
			for _, sandbox in
				{ "pebble", "starterItems", "rarityTables", "CoinRain", "DoubleCoins", "CoinPack" }
			do
				expect(string.find(text, sandbox, 1, true)).toBeNil()
			end
			local _, count = string.gsub(text, "Product5555", "")
			expect(count).toBe(1)
		end
	)

	it("renders no kit and no Modules lookup for --modules none, and no ids without a report", function()
		local text = AdoptInit.renderConfig(TEMPLATE, NewProject.render, "my-game", {}, nil)
		expect(string.find(text, "WaitForChild", 1, true)).toBeNil()
		expect(string.find(text, "Product%d")).toBeNil()
		expect(AdoptInit.reportProducts(nil)).toEqual({})
	end)

	it("says exactly what to do about a ProcessReceipt file", function()
		local msg = AdoptInit.mustFixMessage("src/server/Shop.server.luau", "my-game", { "purchases" })
		expect(msg).toBe(
			"must fix before lint passes: port every product of src/server/Shop.server.luau to ctx.shop.onProduct in modules/my-game/server/init.luau and delete the ProcessReceipt assignment before the first commit (products aren't granted on this branch until then)"
		)
		expect(AdoptInit.mustFixMessage("x.luau", "my-game", { "special" })).toContain("special findings")
		local _, _, mustFix, checks = AdoptInit.legacyList({
			{
				path = "a.luau",
				line = 1,
				check = "purchases",
				message = "only the framework Shop assigns MarketplaceService.ProcessReceipt",
			},
			{ path = "a.luau", line = 2, check = "numbers", message = "n" },
		}, nil)
		expect(mustFix).toEqual({ "a.luau" })
		expect(checks["a.luau"]).toEqual({ "purchases" })
	end)

	it("maps the game module's client part next to its definition", function()
		local merged = AdoptInit.mergeProject(SyncProjects, LEGACY_PROJECT, "legacy-example-a")
		local tree = SyncProjects.decode(merged).vals.tree
		local gm = tree.vals.ReplicatedStorage.vals.GameModule
		expect(gm.vals.client.vals["$path"]).toBe("modules/legacy-example-a/client")
		expect(gm.vals.module.vals["$path"]).toBe("modules/legacy-example-a/module.luau")
		-- an older adopted project (GameModule.module only) gets the client part added
		local old =
			string.gsub(merged, ',%s*"client": {%s*"%$path": "modules/legacy%-example%-a/client"%s*}', "")
		expect(string.find(old, "legacy-example-a/client", 1, true)).toBeNil()
		local again, added = AdoptInit.mergeProject(SyncProjects, old, "legacy-example-a")
		expect(table.find(added, "ReplicatedStorage.GameModule.client")).never.toBeNil()
		expect(again).toBe(merged)
	end)
end)

-- (v1.6.0 dogfood r3) every old Luau source lists the "style" pseudo-check
describe("AdoptInit.legacyList with the old sources (style)", function()
	it(
		"adds style to every old source; a style-only file gets {} in the baseline and the style reason",
		function()
			local findings = AdoptInit.parseFindings(
				"src/server/Shop.server.luau:3: [numbers] balance number in game code\n"
			)
			local list, baseline = AdoptInit.legacyList(
				findings,
				nil,
				{ "src/server/Shop.server.luau", "src/client/Main.client.lua" }
			)
			expect(#list.files).toBe(2)
			expect(list.files[1]).toEqual({
				path = "src/client/Main.client.lua",
				checks = { "style" },
				reason = AdoptInit.STYLE_REASON,
			})
			expect(list.files[2].checks).toEqual({ "numbers", "style" })
			expect(list.files[2].reason).toBe("existing code before StudWork: numbers")
			expect(baseline.files["src/client/Main.client.lua"]).toEqual({})
			expect(baseline.files["src/server/Shop.server.luau"]).toEqual({ numbers = 1 })
			local text = AdoptInit.renderStudworkJson(SyncProjects, nil, baseline)
			expect(text).toContain('"src/client/Main.client.lua": {}')
		end
	)
	it("without old sources nothing changes (older guardrails don't know style)", function()
		local list = AdoptInit.legacyList(AdoptInit.parseFindings(FINDINGS), nil, nil)
		for _, e in list.files do
			expect(table.find(e.checks, "style")).toBeNil()
		end
	end)
end)
