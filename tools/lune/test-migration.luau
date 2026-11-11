--!nocheck
--[[
	tools/lune/test-migration (StudWork v1.6.0, docs/framework/adopting.md §3 "tools/test-migration").
	Usage (through tools/test-migration, which sets the roots):
	  core repo:          tools/test-migration <game dir> [module] [--fixtures <dir>]
	                      (no game: every game with legacy fixtures, one run each)
	  single-game project tools/test-migration [module] [--fixtures <dir>]
	Fixtures: <game>/tests/legacy/*.json (the game module's import) and
	<game>/modules/<module>/tests/legacy/*.json (that module's import), or every *.json in
	--fixtures. Each runs through the game's real import in the sim (MigrationRun.luau, checks
	1-7; MigrationCheck.luau documents the fixture format). Exit 1 on any failure, or when there
	is nothing to run.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local Roots = require("./Roots")
local Harness = require("./testkit/harness")

local function die(msg: string)
	stdio.ewrite("test-migration: " .. msg .. "\n")
	process.exit(1)
end

local positional = {}
local fixturesDir = nil
local i = 1
while i <= #process.args do
	local a = process.args[i]
	if a == "--fixtures" then
		fixturesDir = process.args[i + 1]
		if fixturesDir == nil then
			die("--fixtures needs a folder")
		end
		i += 2
	elseif a == "-h" or a == "--help" then
		print("usage: tools/test-migration [game dir] [module] [--fixtures <dir>]")
		process.exit(0)
	elseif string.sub(a, 1, 2) == "--" then
		die("unknown option " .. a)
	else
		table.insert(positional, a)
		i += 1
	end
end

local gameDir, module
if Roots.single then
	gameDir = "."
	module = positional[1]
else
	gameDir = positional[1]
	module = positional[2]
	if gameDir == nil then
		-- no game given: every game of the project that has legacy fixtures (in the core repo also
		-- tools/test-migration's own example under tools/lune/testdata/migration), one run each
		if fixturesDir ~= nil then
			die("--fixtures needs a game folder")
		end
		local candidates = Roots.gameDirs(fs)
		if not Roots.external then
			local example = "tools/lune/testdata/migration"
			for _, e in (if fs.isDir(example) then fs.readDir(example) else {}) :: { string } do
				if fs.isFile(example .. "/" .. e .. "/default.project.json") then
					table.insert(candidates, example .. "/" .. e)
				end
			end
		end
		local ran, bad = 0, 0
		for _, dir in candidates do
			local has = fs.isDir(dir .. "/tests/legacy")
			if not has and fs.isDir(dir .. "/modules") then
				for _, m in fs.readDir(dir .. "/modules") do
					if fs.isDir(dir .. "/modules/" .. m .. "/tests/legacy") then
						has = true
					end
				end
			end
			if has then
				ran += 1
				local r = process.exec(
					"lune",
					{ "run", Roots.core("tools/lune/test-migration"), dir },
					{ stdio = "inherit" }
				)
				if not r.ok then
					bad += 1
				end
			end
		end
		print(`test-migration: {ran} game(s) with legacy fixtures, {bad} failed`)
		process.exit(if bad > 0 then 1 else 0)
	end
	local found = Roots.findGame(fs, gameDir)
	if found then
		gameDir = found
	end
end
gameDir = string.gsub(gameDir, "/+$", "")
local project = (if gameDir == "." then "" else gameDir .. "/") .. "default.project.json"
if not fs.isFile(project) then
	die(project .. " not found (not a game folder)")
end

local function jsonFiles(dir: string): { string }
	local out = {}
	if not fs.isDir(dir) then
		return out
	end
	for _, e in fs.readDir(dir) do
		if string.match(e, "%.json$") then
			table.insert(out, dir .. "/" .. e)
		end
	end
	table.sort(out)
	return out
end

local function prefixed(path: string): string
	return if gameDir == "." then path else gameDir .. "/" .. path
end

-- { path, module? }
local sources = {}
if fixturesDir then
	for _, f in jsonFiles(fixturesDir) do
		table.insert(sources, { path = f, module = module })
	end
else
	if module == nil then
		for _, f in jsonFiles(prefixed("tests/legacy")) do
			table.insert(sources, { path = f, module = nil })
		end
	end
	local modulesDir = prefixed("modules")
	if fs.isDir(modulesDir) then
		local names = fs.readDir(modulesDir)
		table.sort(names)
		for _, name in names do
			local moduleDir = modulesDir .. "/" .. name
			local moduleName = name
			-- the folder name is lower-case for a game module; module.luau has the real name
			local def = moduleDir .. "/module.luau"
			if fs.isFile(def) then
				moduleName = string.match(fs.readFile(def), 'name%s*=%s*"([%w_]+)"') or name
			end
			if module == nil or module == moduleName or module == name then
				for _, f in jsonFiles(moduleDir .. "/tests/legacy") do
					table.insert(sources, { path = f, module = moduleName })
				end
			end
		end
	end
end
if #sources == 0 then
	die(
		`no legacy fixtures found (looked in {prefixed("tests/legacy")} and {prefixed(
			"modules/*/tests/legacy"
		)})`
	)
end

local fixtures = {}
for _, src in sources do
	local ok, data = pcall(serde.decode, "json", fs.readFile(src.path))
	if not ok then
		die(`{src.path}: not valid JSON ({tostring(data)})`)
	end
	-- a game module's fixtures (tests/legacy at the game root) target the game module's import,
	-- picked by MigrationRun when there is only one import or by the fixture's "import"
	table.insert(fixtures, { name = src.path, module = src.module, data = data })
end

-- the sim indexes the game's folder when it isn't one of its standard roots
local simRoots = process.env.STUDWORK_SIM_ROOTS or ""
if gameDir ~= "." then
	simRoots = if simRoots == "" then gameDir else simRoots .. ":" .. gameDir
end
process.env.STUDWORK_SIM_ROOTS = simRoots
process.env.STUDWORK_MIGRATION_PLAN = serde.encode("json", { project = project, fixtures = fixtures })

local runner = Roots.core("tools/lune/MigrationRun.luau")
print(`test-migration: {#fixtures} fixture(s), game {project}`)
local passed, failed, failures = Harness.runSpec(runner)
for _, f in failures do
	print("  FAIL " .. f)
end
print(string.format("test-migration: %d checks passed, %d failed", passed, failed))
process.exit(if failed > 0 or passed == 0 then 1 else 0)
