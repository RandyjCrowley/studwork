--!nocheck
-- Self-test of tools/make-module, tools/make-migration and tools/make-screen (MakeGen.luau): each
-- generator writes into a scratch folder, the output is checked (and the generated module's own
-- harness test is RUN), then the scratch folder is deleted. The scratch folder sits under
-- templates/ because the test runner only resolves `script.Parent` inside packages/, games/ and
-- templates/ (a migrated module.luau uses script.Parent.migrations).
local MakeGen = require("tools/lune/MakeGen.luau")
local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local fs = luneRequire("@lune/fs")
local luau = luneRequire("@lune/luau")
local process = luneRequire("@lune/process")

local function compiles(source: string, label: string)
	local ok, err = pcall(luau.compile, source)
	if not ok then
		error(label .. " does not compile: " .. tostring(err), 2)
	end
end

local function scratch(tag: string): string
	local dir = string.format("templates/.selftest-%s-%d-%d", tag, os.time(), math.random(1, 1e6))
	assert(not fs.isDir(dir), "scratch folder exists")
	return dir
end

local function cleanup(dir: string)
	if fs.isDir(dir) then
		fs.removeDir(dir)
	end
end

-- runs `tools/test <path>` in a fresh Lune process; returns ok, output
local function runTests(path: string): (boolean, string)
	local result = process.exec("lune", { "run", "tools/lune/testkit/run", path })
	return result.ok, result.stdout .. result.stderr
end

describe("MakeGen names", function()
	it("checks module names and derives folder and data key", function()
		expect(MakeGen.isModuleName("SessionLeaderboard")).toBe(true)
		expect(MakeGen.isModuleName("sessionLeaderboard")).toBe(false)
		expect(MakeGen.isModuleName("Session_Board")).toBe(false)
		expect(MakeGen.kebab("SessionLeaderboard")).toBe("session-leaderboard")
		expect(MakeGen.kebab("HTTPQueue")).toBe("http-queue")
		expect(MakeGen.camel("SessionLeaderboard")).toBe("sessionLeaderboard")
	end)
end)

describe("tools/make-module", function()
	it("writes the §1 anatomy, every Luau file compiles, and its harness test passes", function()
		local root = scratch("module")
		local dir = root .. "/quest-log"
		local ok, err = pcall(function()
			local files, writeErr = MakeGen.writeModule(fs, "QuestLog", dir)
			assert(files, writeErr)
			for _, rel in
				{
					"module.luau",
					"server/init.luau",
					"client/init.luau",
					"tests/QuestLog.spec.luau",
					"README.md",
				}
			do
				expect(fs.isFile(dir .. "/" .. rel)).toBe(true)
			end
			expect(fs.isDir(dir .. "/migrations")).toBe(false) -- created by the first migration
			for rel, source in files do
				if string.match(rel, "%.luau$") then
					compiles(source, rel)
				end
			end
			local def = fs.readFile(dir .. "/module.luau")
			expect(string.find(def, 'name = "QuestLog"', 1, true) ~= nil).toBe(true)
			expect(string.find(def, 'key = "questLog"', 1, true) ~= nil).toBe(true)
			expect(string.find(def, 'replicate = { "visits" }', 1, true) ~= nil).toBe(true)
			-- public API only: no framework internals anywhere in the skeleton
			for rel, source in files do
				for _, internal in
					{ "RuntimeSlot", "Framework/server", "framework/test/harness", "FrameworkClient" }
				do
					expect(string.find(source, internal, 1, true) == nil and rel or internal).toBe(rel)
				end
			end
			local passed, output = runTests(dir)
			if not passed then
				error("generated harness test failed:\n" .. output)
			end
			expect(string.find(output, "2 tests passed, 0 failed", 1, true) ~= nil).toBe(true)
			-- refuses to overwrite
			local again, againErr = MakeGen.writeModule(fs, "QuestLog", dir)
			expect(again).toBeNil()
			expect(string.find(againErr, "already exists", 1, true) ~= nil).toBe(true)
			expect((MakeGen.writeModule(fs, "questLog", root .. "/x"))).toBeNil()
		end)
		cleanup(root)
		if not ok then
			error(err, 0)
		end
	end)

	it("maps the module in a game project (migrations only once they exist)", function()
		local project = {
			tree = {
				ReplicatedStorage = {},
				ServerScriptService = { Modules = { ["$className"] = "Folder" } },
			},
		}
		MakeGen.addToProject(project, "QuestLog", "modules/quest-log")
		local rs = project.tree.ReplicatedStorage.Modules.QuestLog
		expect(rs.module["$path"]).toBe("modules/quest-log/module.luau")
		expect(rs.client["$path"]).toBe("modules/quest-log/client")
		expect(rs.migrations).toBeNil()
		expect(project.tree.ServerScriptService.Modules.QuestLog["$path"]).toBe("modules/quest-log/server")
		MakeGen.addToProject(project, "QuestLog", "modules/quest-log", true)
		expect(project.tree.ReplicatedStorage.Modules.QuestLog.migrations["$path"]).toBe(
			"modules/quest-log/migrations"
		)
		expect(MakeGen.configLine("QuestLog")).toBe(
			'require(GameModules:WaitForChild("QuestLog"):WaitForChild("module")),'
		)
	end)
end)

describe("tools/make-migration", function()
	it(
		"writes the next NNN_ migration + test stub, bumps data.version, and the module still passes",
		function()
			local root = scratch("migration")
			local dir = root .. "/quest-log"
			local ok, err = pcall(function()
				assert(MakeGen.writeModule(fs, "QuestLog", dir))
				local plan, planErr = MakeGen.writeMigration(fs, dir, "Add streak!")
				assert(plan, planErr)
				expect(plan.version).toBe(2)
				expect(plan.file).toBe("002_add_streak")
				expect(fs.isFile(dir .. "/migrations/002_add_streak.luau")).toBe(true)
				expect(fs.isFile(dir .. "/tests/Migration002.spec.luau")).toBe(true)
				compiles(plan.source, "migration")
				compiles(plan.spec, "migration spec")
				local def = fs.readFile(dir .. "/module.luau")
				compiles(def, "module.luau")
				expect(MakeGen.dataVersion(def)).toBe(2)
				expect(string.find(def, "migrations = script.Parent.migrations,", 1, true) ~= nil).toBe(true)
				expect(string.find(def, 'version = "0.1.0"', 1, true) ~= nil).toBe(true) -- module semver untouched

				-- the next one: 003, migrations declared once
				local plan3 = assert(MakeGen.writeMigration(fs, dir, nil))
				expect(plan3.file).toBe("003_migration")
				local def3 = fs.readFile(dir .. "/module.luau")
				expect(MakeGen.dataVersion(def3)).toBe(3)
				local _, declared = string.gsub(def3, "migrations = script%.Parent%.migrations", "")
				expect(declared).toBe(1)

				-- the generated module (now at version 3, with its migrations folder) and both stubs pass
				local passed, output = runTests(dir)
				if not passed then
					error("generated tests failed after make-migration:\n" .. output)
				end
				expect(string.find(output, "6 tests passed, 0 failed", 1, true) ~= nil).toBe(true)
			end)
			cleanup(root)
			if not ok then
				error(err, 0)
			end
		end
	)

	it("refuses a module without a save section or with a migration ahead of data.version", function()
		local noData = 'return StudWork.defineModule({\n\tname = "X",\n\tversion = "1.0.0",\n})\n'
		local plan, err = MakeGen.nextMigration(noData, {}, nil)
		expect(plan).toBeNil()
		expect(string.find(err, "no data", 1, true) ~= nil).toBe(true)
		local withData =
			'return StudWork.defineModule({\n\tname = "X",\n\tdata = {\n\t\tkey = "x",\n\t\tversion = 2,\n\t\tdefault = {},\n\t},\n})\n'
		expect(MakeGen.dataVersion(withData)).toBe(2)
		local ahead, aheadErr = MakeGen.nextMigration(withData, { "003_y.luau" }, nil)
		expect(ahead).toBeNil()
		expect(string.find(aheadErr, "bump data.version", 1, true) ~= nil).toBe(true)
		local okPlan = MakeGen.nextMigration(withData, { "002_y.luau" }, "z")
		expect(okPlan.file).toBe("003_z")
	end)
end)

describe("tools/make-screen", function()
	local MAIN = 'local StudWork = require(game:GetService("ReplicatedStorage"):WaitForChild("Framework"))\n'
		.. 'local Config = {}\n\nStudWork.start(Config)\n\nprint("rest")\n'

	it("writes a screen + the registry once and hooks Main.client after StudWork.start", function()
		local root = scratch("screen")
		local ok, err = pcall(function()
			fs.writeDir(root .. "/src/client")
			fs.writeFile(root .. "/src/client/Main.client.luau", MAIN)
			local written = assert(MakeGen.writeScreen(fs, root, "DailyRewards"))
			expect(#written).toBe(3)
			local screen = fs.readFile(root .. "/src/client/Screens/DailyRewards.luau")
			local registry = fs.readFile(root .. "/src/client/Screens/init.luau")
			local main = fs.readFile(root .. "/src/client/Main.client.luau")
			compiles(screen, "screen")
			compiles(registry, "registry")
			compiles(main, "Main.client")
			expect(string.find(registry, "UI.registerScreen(child.Name", 1, true) ~= nil).toBe(true)
			expect(string.find(screen, 'title = "Daily Rewards"', 1, true) ~= nil).toBe(true)
			-- theme-driven: no hex colours or asset ids in the generated screen
			expect(string.find(screen, "#%x%x%x%x%x%x") == nil).toBe(true)
			expect(string.find(screen, "rbxassetid", 1, true) == nil).toBe(true)
			local startAt = string.find(main, "StudWork.start(Config)", 1, true)
			local hookAt = string.find(main, "registerAll()", 1, true)
			expect(hookAt ~= nil and hookAt > startAt).toBe(true)

			-- a second screen: registry and hook are not duplicated
			local second = assert(MakeGen.writeScreen(fs, root, "Shop"))
			expect(#second).toBe(1)
			local _, hooks =
				string.gsub(fs.readFile(root .. "/src/client/Main.client.luau"), "registerAll%(%)", "")
			expect(hooks).toBe(1)
			-- the same name twice is refused, and so is a bad name
			expect((MakeGen.writeScreen(fs, root, "Shop"))).toBeNil()
			expect((MakeGen.writeScreen(fs, root, "shop"))).toBeNil()
		end)
		cleanup(root)
		if not ok then
			error(err, 0)
		end
	end)

	it("refuses a Main.client without StudWork.start(Config)", function()
		local out, changed, err = MakeGen.hookMain("print('no start')\n")
		expect(out).toBeNil()
		expect(changed).toBe(false)
		expect(string.find(err, "StudWork.start", 1, true) ~= nil).toBe(true)
	end)
end)
