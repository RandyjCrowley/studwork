--!nocheck
-- tools/make-migration (v1.7.1, MakeMigration.luau): data.version as a literal, a reference
-- (`Save.VERSION` from a sibling module, a local), --from, and the migrations/ folder reaching the
-- game's Rojo project, in a single-game project, a games repo and the core repo. Fixtures are
-- written under templates/.selftest-* (generic names) and deleted afterwards; the tool runs as a
-- real process with the project root as its working directory, exactly as tools/_common.sh runs it.
local MakeMigration = require("tools/lune/MakeMigration.luau")
local MakeGen = require("tools/lune/MakeGen.luau")
local SyncProjects = require("tools/lune/SyncProjects.luau")
local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local fs = luneRequire("@lune/fs")
local luau = luneRequire("@lune/luau")
local process = luneRequire("@lune/process")
local serde = luneRequire("@lune/serde")

local function scratch(tag: string): string
	local dir = string.format("templates/.selftest-mm-%s-%d-%d", tag, os.time(), math.random(1, 1e6))
	assert(not fs.isDir(dir), "scratch folder exists")
	return dir
end

local function write(path: string, text: string)
	fs.writeDir(string.match(path, "^(.*)/[^/]+$"))
	fs.writeFile(path, text)
end

local function withScratch(tag: string, fn: (string) -> ())
	local root = scratch(tag)
	local ok, err = pcall(fn, root)
	if fs.isDir(root) then
		fs.removeDir(root)
	end
	if not ok then
		error(err, 0)
	end
end

-- runs tools/lune/make-migration.luau from `cwd`; `up` = the core relative to cwd
local function run(cwd: string, up: string, env: { string }, args: { string })
	local full = table.clone(env)
	table.insert(full, "lune")
	table.insert(full, "run")
	table.insert(full, up .. "/tools/lune/make-migration.luau")
	for _, a in args do
		table.insert(full, a)
	end
	local res = process.exec("env", full, { cwd = cwd })
	return res.code, res.stdout .. res.stderr
end

local function moduleSource(name: string, header: string, versionExpr: string): string
	return 'local ReplicatedStorage = game:GetService("ReplicatedStorage")\n'
		.. 'local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))\n'
		.. 'local GameConfig = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))\n'
		.. header
		.. "\nreturn StudWork.defineModule({\n"
		.. '\tname = "'
		.. name
		.. '",\n\tversion = "1.0.0",\n\tframework = "^1.7.0",\n'
		.. '\tdependsOn = {\n\t\trequire(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module")),\n\t},\n'
		.. "\tdata = {\n\t\tkey = GameConfig.gameId,\n\t\tversion = "
		.. versionExpr
		.. ",\n\t\tdefault = { coins = 0 },\n\t},\n"
		.. '\tserver = "'
		.. name
		.. '",\n})\n'
end

local SAVE =
	"local Save = {}\n\nSave.VERSION = 2\n\nfunction Save.default()\n\treturn { coins = 0 }\nend\n\nreturn Save\n"

local function projectText(gameName: string, modules: { [string]: string }): string
	local rsModules = { ["$className"] = "Folder" }
	local sssModules = { ["$className"] = "Folder" }
	for name, folder in modules do
		rsModules[name] = {
			["$className"] = "Folder",
			module = { ["$path"] = "modules/" .. folder .. "/module.luau" },
		}
		sssModules[name] = { ["$path"] = "modules/" .. folder .. "/server" }
	end
	return serde.encode("json", {
		name = "fixture",
		tree = {
			["$className"] = "DataModel",
			ReplicatedStorage = {
				Game = { ["$path"] = "src/shared" },
				GameModule = {
					["$className"] = "Folder",
					module = { ["$path"] = "modules/" .. gameName .. "/module.luau" },
				},
				Modules = rsModules,
			},
			ServerScriptService = { Modules = sssModules },
		},
	}, true) .. "\n"
end

-- a game at `at` (a project root): the game module with a referenced version, Coins (literal),
-- Gems (a local), Quests (computed), Orphan (not mapped in the project)
local function writeGame(at: string, gameName: string)
	local prefix = if at == "" then "" else at .. "/"
	write(prefix .. "src/shared/Config/init.luau", 'return { gameId = "' .. gameName .. '" }\n')
	write(
		prefix .. "modules/" .. gameName .. "/module.luau",
		moduleSource(
			"MyGame",
			'local Save = require(script.Parent:WaitForChild("shared"):WaitForChild("Save"))\n',
			"Save.VERSION"
		)
	)
	write(prefix .. "modules/" .. gameName .. "/shared/Save.luau", SAVE)
	write(prefix .. "modules/coins/module.luau", moduleSource("Coins", "", "3"))
	write(prefix .. "modules/gems/module.luau", moduleSource("Gems", "local VERSION = 4\n", "VERSION"))
	write(
		prefix .. "modules/quests/module.luau",
		moduleSource("Quests", "local Base = require(script.Parent.Base)\n", "Base.VERSION + 1")
	)
	write(prefix .. "modules/quests/Base.luau", "return { VERSION = 1 }\n")
	write(prefix .. "modules/orphan/module.luau", moduleSource("Orphan", "", "1"))
	write(
		prefix .. "default.project.json",
		projectText(gameName, { Coins = "coins", Gems = "gems", Quests = "quests" })
	)
end

local function project(path: string): any
	return serde.decode("json", fs.readFile(path))
end

describe("MakeMigration: reading data.version", function()
	it("parses --from: positive integers only", function()
		expect(MakeMigration.parseFrom("3")).toBe(3)
		for _, bad in { "0", "-1", "2.5", "x", "" } do
			local n, err = MakeMigration.parseFrom(bad)
			expect(n).toBeNil()
			expect(err).toContain("positive integer")
		end
		expect((MakeMigration.parseFrom(nil))).toBeNil()
	end)

	it("a literal, a sibling module's field, a local and a computed value", function()
		withScratch("resolve", function(root)
			writeGame(root, "my-game")
			local function resolve(folder: string, from: number?)
				local dir = root .. "/modules/" .. folder
				return MakeMigration.resolveVersion(
					fs,
					luau,
					dir,
					fs.readFile(dir .. "/module.luau"),
					from,
					MakeGen
				)
			end
			local lit = resolve("coins")
			expect(lit.version).toBe(3)
			expect(lit.how).toBe("literal")
			local ref = resolve("my-game")
			expect(ref.version).toBe(2)
			expect(ref.how).toBe("evaluated")
			expect(ref.expr).toBe("Save.VERSION")
			expect(resolve("gems").version).toBe(4)
			expect(resolve("quests").version).toBe(2)
			-- --from wins and says so when it disagrees
			local agree = resolve("my-game", 2)
			expect(agree.how).toBe("--from")
			expect(agree.warning).toBeNil()
			local disagree = resolve("my-game", 5)
			expect(disagree.version).toBe(5)
			expect(disagree.warning).toContain("--from 5 disagrees with data.version 2")
			-- unresolvable: a clear error that suggests --from
			write(root .. "/modules/coins/module.luau", moduleSource("Coins", "", "Missing.VERSION"))
			local none, err = resolve("coins")
			expect(none).toBeNil()
			expect(err).toContain("Missing.VERSION")
			expect(err).toContain("--from")
		end)
	end)

	it("bumps the one literal a reference comes from, refuses anything else", function()
		withScratch("bump", function(root)
			writeGame(root, "my-game")
			local gameDir = root .. "/modules/my-game"
			local edit = assert(
				MakeMigration.bumpReference(
					fs,
					luau,
					gameDir,
					fs.readFile(gameDir .. "/module.luau"),
					"Save.VERSION",
					3
				)
			)
			expect(edit.path).toBe(gameDir .. "/shared/Save.luau")
			expect(edit.text).toBe((string.gsub(SAVE, "VERSION = 2", "VERSION = 3")))
			local gems = root .. "/modules/gems"
			local local_ = assert(
				MakeMigration.bumpReference(fs, luau, gems, fs.readFile(gems .. "/module.luau"), "VERSION", 5)
			)
			expect(local_.path).toBe(gems .. "/module.luau")
			expect(local_.text).toContain("local VERSION = 5\n")
			expect(local_.text).toContain("version = VERSION,")
			local quests = root .. "/modules/quests"
			local none, err = MakeMigration.bumpReference(
				fs,
				luau,
				quests,
				fs.readFile(quests .. "/module.luau"),
				"Base.VERSION + 1",
				3
			)
			expect(none).toBeNil()
			expect(err).toContain("Base.VERSION + 1")
		end)
	end)
end)

describe("MakeMigration: the Rojo project", function()
	it("projectFor: a game's modules/<folder>, the project root's modules/<folder>, nothing else", function()
		local g, rel = MakeMigration.projectFor("modules/coins")
		expect(g).toBe(".")
		expect(rel).toBe("modules/coins")
		g, rel = MakeMigration.projectFor("./modules/coins/")
		expect(g).toBe(".")
		g, rel = MakeMigration.projectFor("games/demo/modules/coins")
		expect(g).toBe("games/demo")
		expect(rel).toBe("modules/coins")
		expect((MakeMigration.projectFor("examples/widget"))).toBeNil()
	end)

	it("adds migrations next to the module's node, keeps everything else, and is idempotent", function()
		local text = projectText("my-game", { Coins = "coins" })
		local out, status = MakeMigration.mapMigrations(SyncProjects, text, "modules/my-game")
		expect(status).toBe("added")
		local decoded = serde.decode("json", out)
		expect(decoded.tree.ReplicatedStorage.GameModule.migrations["$path"]).toBe(
			"modules/my-game/migrations"
		)
		expect(decoded.tree.ReplicatedStorage.Modules.Coins.migrations).toBeNil()
		-- only the new entry changed
		local without =
			string.gsub(out, ',\n%s*"migrations": {\n%s*"%$path": "modules/my%-game/migrations"\n%s*}', "")
		expect(without).toBe(SyncProjects.encode(SyncProjects.decode(text)))
		local again, status2 = MakeMigration.mapMigrations(SyncProjects, out, "modules/my-game")
		expect(again).toBeNil()
		expect(status2).toBe("present")
		local _, coins = MakeMigration.mapMigrations(SyncProjects, text, "modules/coins")
		expect(coins).toBe("added")
		local _, missing = MakeMigration.mapMigrations(SyncProjects, text, "modules/orphan")
		expect(missing).toBe("unmapped")
		expect(MakeMigration.mappingSnippet("modules/orphan")).toBe(
			'"migrations": { "$path": "modules/orphan/migrations" }'
		)
	end)

	it("leaves a project alone when a $path already maps the module folder", function()
		local text = serde.encode("json", {
			name = "x",
			tree = {
				["$className"] = "DataModel",
				ReplicatedStorage = { Modules = { Coins = { ["$path"] = "modules/coins" } } },
			},
		}, true)
		local out, status = MakeMigration.mapMigrations(SyncProjects, text, "modules/coins")
		expect(out).toBeNil()
		expect(status).toBe("covered")
	end)
end)

describe("tools/make-migration end to end", function()
	it("single-game project: game module (Save.VERSION), literal, local, --from, mapping", function()
		withScratch("single", function(root)
			writeGame(root, "my-game")
			local env = { "STUDWORK_CORE_DIR=../..", "STUDWORK_LAYOUT=single-game" }
			-- the game module by name: version read through Save, Save.VERSION bumped, GameModule mapped
			local code, out = run(root, "../..", env, { "MyGame", "--name", "add gems" })
			expect(out).toContain(
				"created ./modules/my-game/migrations/003_add_gems.luau (data.version 2 -> 3)"
			)
			expect(code).toBe(0)
			expect(fs.readFile(root .. "/modules/my-game/shared/Save.luau")).toContain("Save.VERSION = 3\n")
			local def = fs.readFile(root .. "/modules/my-game/module.luau")
			expect(def).toContain("version = Save.VERSION,\n\t\tmigrations = script.Parent.migrations,")
			expect(fs.isFile(root .. "/modules/my-game/tests/Migration003.spec.luau")).toBe(true)
			local p = project(root .. "/default.project.json")
			expect(p.tree.ReplicatedStorage.GameModule.migrations["$path"]).toBe("modules/my-game/migrations")
			expect(out).toContain("mapped MyGame migrations/ in default.project.json")
			-- read back: 3, and the next run (by folder path) makes 004 without touching the mapping again
			local before = fs.readFile(root .. "/default.project.json")
			code, out = run(root, "../..", env, { "modules/my-game" })
			expect(code).toBe(0)
			expect(out).toContain("004_migration.luau (data.version 3 -> 4)")
			expect(fs.readFile(root .. "/default.project.json")).toBe(before)
			-- a literal (folder path form, the case the old pattern missed) and a local
			code, out = run(root, "../..", env, { "modules/coins" })
			expect(code).toBe(0)
			expect(fs.readFile(root .. "/modules/coins/module.luau")).toContain("\t\tversion = 4,\n")
			expect(
				project(root .. "/default.project.json").tree.ReplicatedStorage.Modules.Coins.migrations["$path"]
			).toBe("modules/coins/migrations")
			code, out = run(root, "../..", env, { "Gems" })
			expect(code).toBe(0)
			expect(fs.readFile(root .. "/modules/gems/module.luau")).toContain("local VERSION = 5\n")
			-- a computed version: refused with nothing written unless --from opts in to a hand bump
			code, out = run(root, "../..", env, { "Quests" })
			expect(code).toBe(1)
			expect(out).toContain("can't bump it")
			expect(out).toContain("nothing was written")
			expect(out).toContain("--from 2")
			expect(fs.isDir(root .. "/modules/quests/migrations")).toBe(false)
			code, out = run(root, "../..", env, { "Quests", "--from", "2" })
			expect(code).toBe(0)
			expect(out).toContain("couldn't bump it")
			expect(out).toContain("set it to 3 yourself")
			expect(fs.isFile(root .. "/modules/quests/migrations/003_migration.luau")).toBe(true)
			-- --from: validated, used, and a disagreement is reported
			code, out = run(root, "../..", env, { "Coins", "--from", "0" })
			expect(code).toBe(1)
			expect(out).toContain("positive integer")
			code, out = run(root, "../..", env, { "Coins", "--from=7" })
			expect(code).toBe(0)
			expect(out).toContain("--from 7 disagrees with data.version 4")
			expect(fs.isFile(root .. "/modules/coins/migrations/008_migration.luau")).toBe(true)
			-- a module the project doesn't map: refused, the exact mapping printed, nothing written
			code, out = run(root, "../..", env, { "Orphan" })
			expect(code).toBe(1)
			expect(out).toContain('"migrations": { "$path": "modules/orphan/migrations" }')
			expect(out).toContain("nothing was written")
			expect(fs.isDir(root .. "/modules/orphan/migrations")).toBe(false)
			expect(fs.readFile(root .. "/modules/orphan/module.luau")).toContain("\t\tversion = 1,\n")
		end)
	end)

	it("games repo: a module by name, mapped in its game's project", function()
		withScratch("games", function(root)
			writeGame(root .. "/games/demo", "demo")
			local env = { "STUDWORK_CORE_DIR=../..", "STUDWORK_LAYOUT=games-repo" }
			local code, out = run(root, "../..", env, { "Coins" })
			expect(code).toBe(0)
			expect(out).toContain("created games/demo/modules/coins/migrations/004_migration.luau")
			local p = project(root .. "/games/demo/default.project.json")
			expect(p.tree.ReplicatedStorage.Modules.Coins.migrations["$path"]).toBe(
				"modules/coins/migrations"
			)
			code, out = run(root, "../..", env, { "games/demo/modules/demo" })
			expect(code).toBe(0)
			expect(fs.readFile(root .. "/games/demo/modules/demo/shared/Save.luau")).toContain(
				"Save.VERSION = 3\n"
			)
			p = project(root .. "/games/demo/default.project.json")
			expect(p.tree.ReplicatedStorage.GameModule.migrations["$path"]).toBe("modules/demo/migrations")
		end)
	end)

	it("core repo: a game folder path, and a module outside any game (note only)", function()
		withScratch("core", function(root)
			writeGame(root .. "/demo", "demo")
			local code, out = run(".", ".", { "STUDWORK_CORE_DIR=." }, { root .. "/demo/modules/coins" })
			expect(code).toBe(0)
			local p = project(root .. "/demo/default.project.json")
			expect(p.tree.ReplicatedStorage.Modules.Coins.migrations["$path"]).toBe(
				"modules/coins/migrations"
			)
			write(root .. "/loose/widget/module.luau", moduleSource("Widget", "", "1"))
			code, out = run(".", ".", { "STUDWORK_CORE_DIR=." }, { root .. "/loose/widget" })
			expect(code).toBe(0)
			expect(out).toContain("note: map " .. root .. "/loose/widget/migrations")
			expect(fs.isFile(root .. "/loose/widget/migrations/002_migration.luau")).toBe(true)
		end)
	end)
end)
