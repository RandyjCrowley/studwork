--!nocheck
-- tools/adopt --from-place (v1.6.0, docs/framework/adopting.md §1): a tiny place built here with
-- @lune/roblox, extracted into a temp folder. Names are untrusted; every write stays inside --out.
local Scan = require("tools/lune/AdoptScan.luau")
local Audit = require("tools/lune/AdoptAudit.luau")
local Place = require("tools/lune/AdoptPlace.luau")
local lune = (getmetatable(getfenv(1)) :: any).__index.require
local fs = lune("@lune/fs")
local process = lune("@lune/process")
local roblox = lune("@lune/roblox")
local serde = lune("@lune/serde")

local env = {
	fs = fs,
	process = process,
	roblox = roblox,
	serde = serde,
	Scan = Scan,
	Audit = Audit,
	version = "1.6.0",
}
local Instance = roblox.Instance

local function tmpRoot(): string
	local base = process.env.TMPDIR or (process.cwd .. "/.cache")
	local dir = Audit.normalize(base .. "/studwork-adopt-place-spec-" .. tostring(math.random(1, 1e9)))
	fs.writeDir(dir)
	-- compare physical paths (a temp folder may sit behind a symlink)
	local res = process.exec("realpath", { dir })
	return string.gsub(res.stdout, "\n$", "")
end

local function new(class: string, name: string, parent, source: string?)
	local inst = Instance.new(class)
	inst.Name = name
	if source then
		inst.Source = source
	end
	inst.Parent = parent
	return inst
end

local function buildPlace(path: string)
	local game = Instance.new("DataModel")
	local sss = game:GetService("ServerScriptService")
	local main = new("Script", "Main", sss, "print('main')\n")
	main.Disabled = true
	local clientRun = new("Script", "RunsOnClient", sss, "print('c')\n")
	clientRun.RunContext = roblox.Enum.RunContext.Client
	local lib = new("ModuleScript", "Lib", sss, "return {}\n")
	new("ModuleScript", "Util", lib, "return 1\n")
	local systems = new("Folder", "Systems", sss)
	new("Script", "Combat", systems, "print('combat')\n")
	new("Folder", "Empty", sss)
	new("Script", "..", sss, "print('dots')\n")
	new("Script", "a/b", sss, "print('slash')\n")
	new("ModuleScript", "CON", sss, "return 'con'\n")
	new("ModuleScript", "Shop", sss, "return 'Shop'\n")
	new("ModuleScript", "shop", sss, "return 'shop'\n")
	local model = new("Model", "Machine", sss)
	new(
		"Script",
		"Saver",
		model,
		"local s = game:GetService('DataStoreService'):GetDataStore('MachineData')\ns:SetAsync('k', 1)\n"
	)
	local rs = game:GetService("ReplicatedStorage")
	new("RemoteEvent", "Ping", rs)
	new("ModuleScript", "Shared", rs, "return {}\n")
	local sp = game:GetService("StarterPlayer")
	local sps = new("StarterPlayerScripts", "StarterPlayerScripts", sp)
	new("LocalScript", "Input", sps, "print('input')\n")
	local ws = game:GetService("Workspace")
	local part = new("Part", "Door", ws)
	new(
		"Script",
		"DoorShop",
		part,
		"game:GetService('MarketplaceService').ProcessReceipt = function(r) return Enum.ProductPurchaseDecision.PurchaseGranted end\n"
	)
	fs.writeFile(path, roblox.serializePlace(game))
end

local function readJson(path: string)
	return serde.decode("json", fs.readFile(path))
end

local function allFiles(root: string, rel: string?, out)
	out = out or {}
	local abs = if rel then root .. "/" .. rel else root
	for _, e in fs.readDir(abs) do
		local r = if rel then rel .. "/" .. e else e
		if fs.isDir(abs .. "/" .. e) then
			allFiles(root, r, out)
		else
			table.insert(out, r)
		end
	end
	table.sort(out)
	return out
end

describe("AdoptPlace.sanitize", function()
	it("escapes separators, dots, reserved names, Rojo suffixes and control characters", function()
		expect((Place.sanitize("Main"))).toBe("Main")
		expect(select(2, Place.sanitize("Main"))).toBe(false)
		expect((Place.sanitize(".."))).toBe("__")
		expect((Place.sanitize("."))).toBe("_")
		expect((Place.sanitize("a/b"))).toBe("a_b")
		expect((Place.sanitize('a\\b:c*d?e"f<g>h|i'))).toBe("a_b_c_d_e_f_g_h_i")
		expect((Place.sanitize("CON"))).toBe("_CON")
		expect((Place.sanitize("lpt1.txt"))).toBe("_lpt1_txt")
		expect((Place.sanitize("init"))).toBe("_init")
		expect((Place.sanitize("Foo.server"))).toBe("Foo_server")
		expect((Place.sanitize("tab\there"))).toBe("tab_here")
		expect((Place.sanitize("trailing. "))).toBe("trailing__")
		expect(select(2, Place.sanitize("a/b"))).toBe(true)
	end)
end)

describe("AdoptPlace.run", function()
	it(
		"extracts the code containers with meta, a manifest, a containers-only project and the report",
		function()
			local root = tmpRoot()
			local placePath = root .. "/game.rbxl"
			buildPlace(placePath)
			local out = root .. "/out"
			local res, err = Place.run(env, placePath, out)
			expect(err).toBeNil()
			local files = allFiles(out)
			for _, f in
				{
					"default.project.json",
					".studwork-from-place.json",
					"studwork-adopt-report.json",
					"studwork-adopt-report.md",
					"src/ServerScriptService/Main.server.luau",
					"src/ServerScriptService/Main.meta.json",
					"src/ServerScriptService/RunsOnClient.server.luau",
					"src/ServerScriptService/Lib/init.luau",
					"src/ServerScriptService/Lib/Util.luau",
					"src/ServerScriptService/Systems/Combat.server.luau",
					"src/ServerScriptService/__.server.luau",
					"src/ServerScriptService/a_b.server.luau",
					"src/ServerScriptService/_CON.luau",
					"src/ServerScriptService/Shop.luau",
					"src/ServerScriptService/shop~2.luau",
					"src/ReplicatedStorage/Shared.luau",
					"src/StarterPlayer/StarterPlayerScripts/Input.client.luau",
				}
			do
				expect(files).toContain(f)
			end
			-- nothing for the empty folder, the model's script or the workspace script
			for _, f in files do
				expect(string.find(f, "Empty", 1, true)).toBeNil()
				expect(string.find(f, "Saver", 1, true)).toBeNil()
				expect(string.find(f, "DoorShop", 1, true)).toBeNil()
			end
			expect(fs.readFile(out .. "/src/ServerScriptService/Lib/Util.luau")).toBe("return 1\n")
			expect(readJson(out .. "/src/ServerScriptService/Main.meta.json").properties.Disabled).toBe(true)
			-- the model stays in the place, so the container keeps unknown instances
			expect(readJson(out .. "/src/ServerScriptService/RunsOnClient.meta.json").properties.RunContext).toBe(
				"Client"
			)
			expect(readJson(out .. "/src/ServerScriptService/__.meta.json").properties.Name).toBe("..")
			expect(readJson(out .. "/src/ServerScriptService/a_b.meta.json").properties.Name).toBe("a/b")
			expect(readJson(out .. "/src/ServerScriptService/_CON.meta.json").properties.Name).toBe("CON")
			expect(readJson(out .. "/src/ServerScriptService/shop~2.meta.json").properties.Name).toBe("shop")
			expect(fs.isFile(out .. "/src/ServerScriptService/Shop.meta.json")).toBe(false)
			expect(#res.collisions).toBe(1)
			expect(res.collisions[1].name).toBe("shop")

			local project = readJson(out .. "/default.project.json")
			expect(project.tree.ServerScriptService["$path"]).toBe("src/ServerScriptService")
			expect(project.tree.ServerScriptService["$ignoreUnknownInstances"]).toBe(true)
			expect(project.tree.StarterPlayer.StarterPlayerScripts["$path"]).toBe(
				"src/StarterPlayer/StarterPlayerScripts"
			)
			expect(project.tree.ReplicatedStorage["$ignoreUnknownInstances"]).toBe(true)
			expect(project.tree.ServerStorage).toBeNil()
			local text = fs.readFile(out .. "/default.project.json")
			expect(string.find(text, "Framework", 1, true)).toBeNil()
			expect(string.find(text, "studwork", 1, true)).toBeNil()

			local manifest = readJson(out .. "/.studwork-from-place.json")
			expect(manifest.placeFile).toBe("../game.rbxl")
			expect(manifest.files["src/ServerScriptService/Main.server.luau"]).toBe(
				serde.hash("sha256", "print('main')\n")
			)
			expect(manifest.files["studwork-adopt-report.json"]).toBeNil()
			-- Rojo syncs the file name, so every renamed instance is listed for the agent
			expect(manifest.renamed["src/ServerScriptService/a_b"]).toBe("a/b")
			expect(manifest.renamed["src/ServerScriptService/shop~2"]).toBe("shop")
			expect(manifest.renamed["src/ServerScriptService/Main"]).toBeNil()
			expect(#res.renamed).toBe(4)

			local report = readJson(out .. "/studwork-adopt-report.json")
			local left = {}
			for _, n in report.notExtracted do
				left[n.path] = n
			end
			expect(left["place:Workspace.Door.DoorShop"] ~= nil).toBe(true)
			expect(left["place:ServerScriptService.Machine.Saver"] ~= nil).toBe(true)
			expect(report.projects[1].placeFile).toBe("../game.rbxl")

			-- --verify refuses while a script left in the place saves or sells
			local issues = Audit.verifyIssues(env, out)
			local text2 = table.concat(issues, "\n")
			expect(text2).toContain("left in the place: place:Workspace.Door.DoorShop")
			expect(text2).toContain("left in the place: place:ServerScriptService.Machine.Saver")

			-- the place file is untouched and nothing was written outside --out
			expect(allFiles(root)).toContain("game.rbxl")
			for _, f in allFiles(root) do
				expect(f == "game.rbxl" or string.sub(f, 1, 4) == "out/").toBe(true)
			end
			fs.removeDir(root)
		end
	)

	it("re-runs over its own unchanged files, refuses a changed one and a non-empty fresh --out", function()
		local root = tmpRoot()
		local placePath = root .. "/game.rbxl"
		buildPlace(placePath)
		-- default --out: the place's folder (the place file itself is allowed there)
		local res, err = Place.run(env, placePath, root)
		expect(err).toBeNil()
		expect(res ~= nil).toBe(true)
		local again, err2 = Place.run(env, placePath, root)
		expect(err2).toBeNil()
		expect(again ~= nil).toBe(true)

		local target = root .. "/src/ServerScriptService/Main.server.luau"
		fs.writeFile(target, "print('edited by hand')\n")
		local refused, err3 = Place.run(env, placePath, root)
		expect(refused).toBeNil()
		expect(err3).toContain("src/ServerScriptService/Main.server.luau")
		expect(fs.readFile(target)).toBe("print('edited by hand')\n")

		local other = root .. "/other"
		fs.writeDir(other)
		fs.writeFile(other .. "/notes.txt", "mine")
		-- (v1.6.0 dogfood) unrelated files in a fresh --out (a game's saves/, notes) are kept
		local ok2, err4 = Place.run(env, placePath, other)
		expect(err4).toBeNil()
		expect(ok2 ~= nil).toBe(true)
		expect(fs.readFile(other .. "/notes.txt")).toBe("mine")
		-- ...but a file at a path the run writes, with no manifest, is refused and left alone
		local third = root .. "/third"
		fs.writeDir(third)
		fs.writeFile(third .. "/default.project.json", "{}")
		local refused3, err5 = Place.run(env, placePath, third)
		expect(refused3).toBeNil()
		expect(err5).toContain("default.project.json")
		expect(allFiles(third)).toEqual({ "default.project.json" })
		fs.removeDir(root)
	end)

	it("stops before writing anything when a target resolves outside --out through a symlink", function()
		local root = tmpRoot()
		local placePath = root .. "/game.rbxl"
		buildPlace(placePath)
		local out = root .. "/out"
		expect(Place.run(env, placePath, out) ~= nil).toBe(true)
		local outside = root .. "/outside"
		fs.writeDir(outside)
		fs.removeDir(out .. "/src")
		local ln = process.exec("ln", { "-s", outside, out .. "/src" })
		expect(ln.ok).toBe(true)
		local before = fs.readFile(out .. "/default.project.json")
		local res, err = Place.run(env, placePath, out)
		expect(res).toBeNil()
		expect(err).toContain("outside --out")
		expect(fs.readDir(outside)).toEqual({})
		expect(fs.readFile(out .. "/default.project.json")).toBe(before)
		fs.removeDir(root)
	end)

	it("refuses a file that isn't a place and a place without code", function()
		local root = tmpRoot()
		fs.writeFile(root .. "/x.txt", "x")
		local res, err = Place.run(env, root .. "/x.txt", root .. "/out")
		expect(res).toBeNil()
		expect(err).toContain("not a place file")
		local game = Instance.new("DataModel")
		new("Part", "P", game:GetService("Workspace"))
		fs.writeFile(root .. "/empty.rbxl", roblox.serializePlace(game))
		local res2, err2 = Place.run(env, root .. "/empty.rbxl", root .. "/out2")
		expect(res2).toBeNil()
		expect(err2).toContain("no scripts in a code container")
		expect(fs.isDir(root .. "/out2")).toBe(false)
		fs.removeDir(root)
	end)

	it("audits a bare place file, listing scripts outside the code containers", function()
		local root = tmpRoot()
		buildPlace(root .. "/game.rbxl")
		local report = Audit.run(env, { root .. "/game.rbxl" }, { write = false })
		expect(report.projects[1].kind).toBe("place")
		expect(report.projects[1].placeFile).toBe("game.rbxl")
		local left = {}
		for _, n in report.notExtracted do
			left[n.path] = true
		end
		expect(left["Workspace.Door.DoorShop"]).toBe(true)
		local crit = {}
		for _, r in report.risks do
			crit[string.match(r.id, "^([^:]+)")] = r.level
		end
		expect(crit.receipt_no_history).toBe("critical")
		expect(crit.not_extracted).toBe("high")
		fs.removeDir(root)
	end)
end)

-- (v1.6.0 dogfood r2) tools/adopt --strip-place: a tiny place built here, a project around it
describe("AdoptPlace.strip", function()
	local function stripProject(xml: boolean): (string, string)
		local root = tmpRoot()
		local game = Instance.new("DataModel")
		local sg = game:GetService("StarterGui")
		local gui = new("ScreenGui", "ShopGui", sg)
		new(
			"LocalScript",
			"ShopGuiClient",
			gui,
			"game:GetService('MarketplaceService'):PromptProductPurchase(nil, 1)\n"
		)
		new("Frame", "Panel", gui)
		local rs = game:GetService("ReplicatedStorage")
		local remotes = new("Folder", "Remotes", rs)
		new("RemoteEvent", "Buy", remotes)
		local ws = game:GetService("Workspace")
		local pad = new("Part", "CoinPad", ws)
		new("Script", "CoinPadScript", pad, "print('pad')\n")
		new("Part", "Map.v2", ws) -- a name with a dot
		local file = if xml then "my-game.rbxlx" else "my-game.rbxl"
		fs.writeFile(root .. "/" .. file, roblox.serializePlace(game, xml))
		fs.writeFile(
			root .. "/studwork.json",
			'{\n  "layout": "single-game",\n  "framework": "studwork",\n  "adopted": true,\n  "placeFile": "'
				.. file
				.. '",\n  "legacyBaseline": {\n    "files": {}\n  }\n}\n'
		)
		return root, file
	end
	local function load(path: string)
		return roblox.deserializePlace(fs.readFile(path))
	end

	it(
		"writes <name>.studwork.rbxlx without the named instances, repoints studwork.json, keeps the original",
		function()
			local root, file = stripProject(true)
			local original = fs.readFile(root .. "/" .. file)
			local res, err =
				Place.strip(env, root, { "StarterGui.ShopGui.ShopGuiClient", "ReplicatedStorage.Remotes" })
			expect(err).toBeNil()
			expect(res.out).toBe("my-game.studwork.rbxlx")
			expect(fs.readFile(root .. "/" .. file)).toBe(original)
			local copy = load(root .. "/my-game.studwork.rbxlx")
			expect(#Place.find(copy, "StarterGui.ShopGui.ShopGuiClient")).toBe(0)
			expect(#Place.find(copy, "ReplicatedStorage.Remotes")).toBe(0)
			expect(#Place.find(copy, "StarterGui.ShopGui.Panel")).toBe(1) -- the UI itself stays
			expect(#Place.find(copy, "Workspace.CoinPad.CoinPadScript")).toBe(1)
			local marker = readJson(root .. "/studwork.json")
			expect(marker.placeFile).toBe("my-game.studwork.rbxlx")
			expect(marker.adopted).toBe(true)
			expect(marker.legacyBaseline).toEqual({ files = {} })
			-- repeatable: on the copy it removes more, the original still untouched
			local res2 = Place.strip(env, root, { "Workspace.CoinPad.CoinPadScript" })
			expect(res2.out).toBe("my-game.studwork.rbxlx")
			expect(res2.markerChanged).toBe(false)
			local copy2 = load(root .. "/my-game.studwork.rbxlx")
			expect(#Place.find(copy2, "Workspace.CoinPad.CoinPadScript")).toBe(0)
			expect(#Place.find(copy2, "Workspace.CoinPad")).toBe(1)
			expect(fs.readFile(root .. "/" .. file)).toBe(original)
			fs.removeDir(root)
		end
	)

	it("keeps the binary format for .rbxl and matches names with dots", function()
		local root = stripProject(false)
		local res, err = Place.strip(env, root, { "Workspace.Map.v2" })
		expect(err).toBeNil()
		expect(res.out).toBe("my-game.studwork.rbxl")
		local copy = load(root .. "/my-game.studwork.rbxl")
		expect(#Place.find(copy, "Workspace.Map.v2")).toBe(0)
		expect(string.sub(fs.readFile(root .. "/my-game.studwork.rbxl"), 1, 8)).toBe("<roblox!")
		fs.removeDir(root)
	end)

	it("refuses a path that doesn't exist, writing nothing", function()
		local root, file = stripProject(true)
		local before = fs.readFile(root .. "/studwork.json")
		local res, err = Place.strip(env, root, { "ReplicatedStorage.Remotes", "StarterGui.NoSuchGui" })
		expect(res).toBeNil()
		expect(err).toContain("StarterGui.NoSuchGui: no such instance in " .. file)
		expect(err).toContain("Nothing was written")
		expect(fs.isFile(root .. "/my-game.studwork.rbxlx")).toBe(false)
		expect(fs.readFile(root .. "/studwork.json")).toBe(before)
		fs.removeDir(root)
	end)

	it("refuses without a placeFile, and a stale copy studwork.json doesn't point at", function()
		local root = tmpRoot()
		fs.writeFile(root .. "/studwork.json", '{ "layout": "single-game", "adopted": true }\n')
		local _, e1 = Place.strip(env, root, { "Workspace.X" })
		expect(e1).toContain('no "placeFile"')
		fs.removeDir(root)
		local root2 = stripProject(true)
		fs.writeFile(root2 .. "/my-game.studwork.rbxlx", "old copy")
		local _, e2 = Place.strip(env, root2, { "ReplicatedStorage.Remotes" })
		expect(e2).toContain("already exists")
		expect(fs.readFile(root2 .. "/my-game.studwork.rbxlx")).toBe("old copy")
		fs.removeDir(root2)
	end)
end)

-- (v1.6.0 dogfood r3) the extracted scripts stay in the place: --from-place records them,
-- the audit lists them (placeDuplicates), --verify refuses, --strip-place --extracted removes them
describe("AdoptPlace: extracted scripts left in the place", function()
	local function project(): (string, string)
		local root = tmpRoot()
		local game = Instance.new("DataModel")
		local sss = game:GetService("ServerScriptService")
		local saver = new("Script", "DataManager", sss, "print('save')\n")
		new("ModuleScript", "Helper", saver, "return 1\n") -- goes with its script
		local systems = new("Folder", "Systems", sss)
		new("Script", "Combat", systems, "print('combat')\n")
		local rs = game:GetService("ReplicatedStorage")
		new("ModuleScript", "Items", rs, "return {}\n")
		new("RemoteEvent", "Buy", rs) -- not a script: never recorded
		local ws = game:GetService("Workspace")
		local pad = new("Part", "Pad", ws)
		new("Script", "PadScript", pad, "print('pad')\n") -- not extracted (not a code container)
		fs.writeFile(root .. "/my-game.rbxlx", roblox.serializePlace(game, true))
		local res, err = Place.run(env, root .. "/my-game.rbxlx", root)
		assert(res, err)
		fs.writeFile(
			root .. "/studwork.json",
			'{\n  "layout": "single-game",\n  "framework": "studwork",\n  "adopted": true,\n  "placeFile": "my-game.rbxlx"\n}\n'
		)
		return root, "my-game.rbxlx"
	end
	local EXTRACTED = {
		"ReplicatedStorage.Items",
		"ServerScriptService.DataManager",
		"ServerScriptService.Systems.Combat",
	}

	it("--from-place records every extracted script (topmost only) in the manifest", function()
		local root = project()
		expect(readJson(root .. "/" .. Audit.MANIFEST).extracted).toEqual(EXTRACTED)
		fs.removeDir(root)
	end)

	it("the audit lists them as placeDuplicates (high risk, a plan step); --verify refuses", function()
		local root = project()
		local report = Audit.run(env, { root }, { write = false })
		local paths = {}
		for _, d in report.placeDuplicates do
			table.insert(paths, d.path)
		end
		expect(paths).toEqual(EXTRACTED)
		local high = {}
		for _, r in report.risks do
			if r.level == "high" then
				high[string.match(r.id, "^([^:]+)")] = true
			end
		end
		expect(high.place_duplicate).toBe(true)
		local ids = {}
		for _, s in report.plan do
			ids[s.id] = true
		end
		expect(ids["strip-place"]).toBe(true)
		expect(Audit.markdown(report)).toContain("## Extracted scripts still in the place")
		local issues = Audit.verifyIssues(env, root)
		expect(table.concat(issues, "\n")).toContain(
			"`ServerScriptService.DataManager` is still in my-game.rbxlx (old code runs next to StudWork): run tools/adopt --strip-place . --extracted"
		)
		fs.removeDir(root)
	end)

	it(
		"--strip-place --extracted removes every recorded one still there; then --verify passes that check",
		function()
			local root, file = project()
			local original = fs.readFile(root .. "/" .. file)
			local res, err = Place.strip(env, root, {}, { extracted = true })
			expect(err).toBeNil()
			expect(#res.removed).toBe(3)
			expect(res.out).toBe("my-game.studwork.rbxlx")
			expect(fs.readFile(root .. "/" .. file)).toBe(original)
			local copy = roblox.deserializePlace(fs.readFile(root .. "/my-game.studwork.rbxlx"))
			for _, p in EXTRACTED do
				expect(#Place.find(copy, p)).toBe(0)
			end
			expect(#Place.find(copy, "ReplicatedStorage.Buy")).toBe(1)
			expect(#Place.find(copy, "Workspace.Pad.PadScript")).toBe(1)
			local issues = Audit.verifyIssues(env, root)
			expect(string.find(table.concat(issues, "\n"), "is still in", 1, true)).toBeNil()
			-- a rerun is a no-op (nothing left), never an error
			local again, err2 = Place.strip(env, root, {}, { extracted = true })
			expect(err2).toBeNil()
			expect(again.nothing).toBe(true)
			fs.removeDir(root)
		end
	)

	it("--extracted with named paths strips both; an older manifest without the list is refused", function()
		local root = project()
		local res = Place.strip(env, root, { "Workspace.Pad.PadScript" }, { extracted = true })
		expect(#res.removed).toBe(4)
		fs.removeDir(root)
		local root2 = project()
		local m = readJson(root2 .. "/" .. Audit.MANIFEST)
		m.extracted = nil
		fs.writeFile(root2 .. "/" .. Audit.MANIFEST, serde.encode("json", m))
		local none, e = Place.strip(env, root2, {}, { extracted = true })
		expect(none).toBeNil()
		expect(e).toContain('has no "extracted" list')
		-- the audit still finds them (derived: every script --from-place would extract)
		expect(#Audit.run(env, { root2 }, { write = false }).placeDuplicates).toBe(3)
		fs.removeDir(root2)
	end)
end)

-- (v1.6.1, final review L4) the original place is known by its recorded content hash, not by its
-- name: --strip-place and --from-place never write over it, whatever it is called
describe("AdoptPlace: the original place is recorded by hash", function()
	local function placeBytes(): string
		local game = Instance.new("DataModel")
		local rs = game:GetService("ReplicatedStorage")
		local remotes = new("Folder", "Remotes", rs)
		new("RemoteEvent", "Buy", remotes)
		local sss = game:GetService("ServerScriptService")
		new("Script", "Main", sss, "print('main')\n")
		return roblox.serializePlace(game, true)
	end
	local function marker(file: string): string
		return '{\n  "layout": "single-game",\n  "framework": "studwork",\n  "adopted": true,\n  "placeFile": "'
			.. file
			.. '"\n}\n'
	end
	local function sha(text: string): string
		return serde.hash("sha256", text)
	end

	it("--from-place records the original's name, path and sha256", function()
		local root = tmpRoot()
		local bytes = placeBytes()
		fs.writeFile(root .. "/my-game.rbxlx", bytes)
		local res, err = Place.run(env, root .. "/my-game.rbxlx", root)
		expect(err).toBeNil()
		expect(res).never.toBeNil()
		local m = readJson(root .. "/" .. Audit.MANIFEST)
		expect(m.original).toEqual({ name = "my-game.rbxlx", path = "my-game.rbxlx", sha256 = sha(bytes) })
		fs.removeDir(root)
	end)

	it("--strip-place refuses an original named <x>.studwork.rbxlx (recorded by --from-place)", function()
		local root = tmpRoot()
		local bytes = placeBytes()
		fs.writeFile(root .. "/x.studwork.rbxlx", bytes)
		assert(Place.run(env, root .. "/x.studwork.rbxlx", root))
		fs.writeFile(root .. "/studwork.json", marker("x.studwork.rbxlx"))
		local res, err = Place.strip(env, root, { "ReplicatedStorage.Remotes" })
		expect(res).toBeNil()
		expect(err).toContain("x.studwork.rbxlx is the original place")
		expect(err).toContain("Nothing was written")
		expect(fs.readFile(root .. "/x.studwork.rbxlx")).toBe(bytes)
		fs.removeDir(root)
	end)

	it("--strip-place refuses a copy-named place when no original is recorded or next to it", function()
		local root = tmpRoot()
		local bytes = placeBytes()
		fs.writeFile(root .. "/x.studwork.rbxlx", bytes)
		fs.writeFile(root .. "/studwork.json", marker("x.studwork.rbxlx"))
		local res, err = Place.strip(env, root, { "ReplicatedStorage.Remotes" })
		expect(res).toBeNil()
		expect(err).toContain("may be the original itself")
		expect(fs.readFile(root .. "/x.studwork.rbxlx")).toBe(bytes)
		fs.removeDir(root)
	end)

	it(
		"--strip-place records the original, then refuses a placeFile hand-edited to the original's bytes",
		function()
			local root = tmpRoot()
			local bytes = placeBytes()
			fs.writeFile(root .. "/my-game.rbxlx", bytes)
			fs.writeFile(root .. "/studwork.json", marker("my-game.rbxlx"))
			local res, err = Place.strip(env, root, { "ReplicatedStorage.Remotes" })
			expect(err).toBeNil()
			expect(res.out).toBe("my-game.studwork.rbxlx")
			local m = readJson(root .. "/" .. Audit.MANIFEST)
			expect(m.original.sha256).toBe(sha(bytes))
			expect(m.original.name).toBe("my-game.rbxlx")
			-- a later strip of the copy still works (the copy's hash isn't the original's)
			local res2, err2 = Place.strip(env, root, { "ServerScriptService.Main" })
			expect(err2).toBeNil()
			expect(res2.out).toBe("my-game.studwork.rbxlx")
			-- placeFile hand-edited to a copy-named file that is in fact the original
			fs.writeFile(root .. "/orig.studwork.rbxlx", bytes)
			fs.writeFile(root .. "/studwork.json", marker("orig.studwork.rbxlx"))
			local res3, err3 = Place.strip(env, root, { "ReplicatedStorage" })
			expect(res3).toBeNil()
			expect(err3).toContain("is the original place")
			expect(fs.readFile(root .. "/orig.studwork.rbxlx")).toBe(bytes)
			expect(fs.readFile(root .. "/my-game.rbxlx")).toBe(bytes)
			fs.removeDir(root)
		end
	)

	it("--strip-place refuses when the copy it would write holds the original's bytes", function()
		local root = tmpRoot()
		local bytes = placeBytes()
		fs.writeFile(root .. "/my-game.studwork.rbxlx", bytes) -- the original, under the copy's name
		fs.writeFile(root .. "/my-game.rbxlx", placeBytes() .. "\n") -- a different file
		fs.writeFile(
			root .. "/" .. Audit.MANIFEST,
			serde.encode("json", { original = { name = "o.rbxlx", path = "o.rbxlx", sha256 = sha(bytes) } })
		)
		fs.writeFile(root .. "/studwork.json", marker("my-game.rbxlx"))
		local res, err = Place.strip(env, root, { "ReplicatedStorage.Remotes" })
		expect(res).toBeNil()
		expect(err).toContain("refusing to write my-game.studwork.rbxlx: its content is the original place's")
		expect(fs.readFile(root .. "/my-game.studwork.rbxlx")).toBe(bytes)
		fs.removeDir(root)
	end)

	it("--from-place refuses an --out that is the original, or a target holding its bytes", function()
		local root = tmpRoot()
		local bytes = placeBytes()
		fs.writeFile(root .. "/my-game.rbxlx", bytes)
		local res, err = Place.run(env, root .. "/my-game.rbxlx", root .. "/my-game.rbxlx")
		expect(res).toBeNil()
		expect(err).toContain("--out is the original place file")
		expect(fs.readFile(root .. "/my-game.rbxlx")).toBe(bytes)
		-- a file the run would write that holds the original's bytes (a renamed original)
		fs.writeDir(root .. "/out")
		fs.writeFile(root .. "/out/default.project.json", bytes)
		local res2, err2 = Place.run(env, root .. "/my-game.rbxlx", root .. "/out")
		expect(res2).toBeNil()
		expect(err2).toContain("refusing to write default.project.json")
		expect(err2).toContain("the original place's")
		expect(fs.readFile(root .. "/out/default.project.json")).toBe(bytes)
		fs.removeDir(root)
	end)
end)
