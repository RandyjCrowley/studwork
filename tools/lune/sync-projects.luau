--!nocheck
--[[
	tools/sync-projects [--check]: (re)writes the GENERATED `Modules` entries of every
	*.project.json under games/, templates/ and examples/ (and, v1.5.0, the root *.project.json of a
	single-game project) (v1.3.1 R19, module-api.md §1;
	logic in SyncProjects.luau, module folders from ModuleDiscovery.luau). --check writes nothing
	and exits 1 listing every project that drifts (tools/lint runs it).
	(v1.7.0) Also maps a game's src/shared/Localization into LocalizationService in its projects,
	and writes each game's src/shared/Config/Environments.luau from its deploy.json (every folder
	with a deploy.json and a src/shared/Config folder). Equal test and live place ids in a
	deploy.json fail both modes; --check also fails when an Environments.luau is out of date.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local ModuleDiscovery = require("./ModuleDiscovery")
local SyncProjects = require("./SyncProjects")

local check = process.args[1] == "--check"

local projects = {}
local gameDirs = {} -- folders holding a deploy.json (v1.7.0: Environments.luau)
local function walk(dir: string)
	if not fs.isDir(dir) then
		return
	end
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			-- (v1.6.0) examples/legacy: fixtures of NON-StudWork games (no Modules entries)
			if
				entry ~= "Packages"
				and entry ~= "node_modules"
				and entry ~= ".git"
				and path ~= "examples/legacy"
			then
				walk(path)
			end
		elseif string.match(entry, "%.project%.json$") then
			table.insert(projects, path)
		elseif entry == "deploy.json" then
			table.insert(gameDirs, dir)
		end
	end
end
for _, root in { "games", "templates", "examples" } do
	walk(root)
end
-- (v1.5.0) a single-game project's own Rojo projects sit at its root (default.project.json, ...)
if require("./Roots").single then
	for _, entry in fs.readDir(".") do
		if fs.isFile(entry) and string.match(entry, "%.project%.json$") then
			table.insert(projects, entry)
		end
	end
	if fs.isFile("deploy.json") then
		table.insert(gameDirs, ".")
	end
end
table.sort(projects)
table.sort(gameDirs)

local function under(dir: string, rel: string): string
	return if dir == "." then rel else dir .. "/" .. rel
end

local entries = ModuleDiscovery.discover(fs, require("./Roots").CORE)
local drift = 0
for _, path in projects do
	local text = fs.readFile(path)
	local dir = string.match(path, "^(.*)/[^/]+$") or "."
	local out, changes = SyncProjects.sync(path, text, entries, {
		localization = fs.isDir(under(dir, SyncProjects.LOCALIZATION_PATH)),
	})
	if out ~= text then
		drift += 1
		if check then
			print(`{path}: drifts from tools/sync-projects ({table.concat(changes, "; ")})`)
		else
			fs.writeFile(path, out)
			print(`{path}: {table.concat(changes, "; ")}`)
		end
	end
end
local failed = 0
local envFiles = 0
for _, dir in gameDirs do
	if not fs.isDir(under(dir, "src/shared/Config")) then
		continue
	end
	envFiles += 1
	local target = under(dir, SyncProjects.ENV_PATH)
	local generated, errors =
		SyncProjects.environments(fs.readFile(under(dir, "deploy.json")), under(dir, "deploy.json"))
	if generated == nil then
		failed += 1
		for _, e in errors do
			print(e)
		end
		continue
	end
	local current = if fs.isFile(target) then fs.readFile(target) else nil
	if current ~= generated then
		drift += 1
		if check then
			print(`{target}: drifts from deploy.json (run tools/sync-projects)`)
		else
			fs.writeFile(target, generated)
			print(`{target}: generated from deploy.json`)
		end
	end
end
if failed > 0 then
	print(`sync-projects: {failed} deploy.json file(s) can't be used (see above)`)
	process.exit(1)
end
if check and drift > 0 then
	print(`sync-projects: {drift} file(s) drift; run tools/sync-projects`)
	process.exit(1)
end
print(
	`sync-projects: {if check then "clean" else "done"} ({#projects} project(s), {#entries} module folder(s), {envFiles} Environments.luau)`
)
