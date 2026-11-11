--!nocheck
--[[
	tools/sync-projects [--check]: (re)writes the GENERATED `Modules` entries of every
	*.project.json under games/, templates/ and examples/ (v1.3.1 R19, module-api.md §1;
	logic in SyncProjects.luau, module folders from ModuleDiscovery.luau). --check writes nothing
	and exits 1 listing every project that drifts (tools/lint runs it).
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local ModuleDiscovery = require("./ModuleDiscovery")
local SyncProjects = require("./SyncProjects")

local check = process.args[1] == "--check"

local projects = {}
local function walk(dir: string)
	if not fs.isDir(dir) then
		return
	end
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			if entry ~= "Packages" and entry ~= "node_modules" and entry ~= ".git" then
				walk(path)
			end
		elseif string.match(entry, "%.project%.json$") then
			table.insert(projects, path)
		end
	end
end
for _, root in { "games", "templates", "examples" } do
	walk(root)
end
table.sort(projects)

local entries = ModuleDiscovery.discover(fs, require("./Roots").CORE)
local drift = 0
for _, path in projects do
	local text = fs.readFile(path)
	local out, changes = SyncProjects.sync(path, text, entries)
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
if check and drift > 0 then
	print(`sync-projects: {drift} project(s) drift; run tools/sync-projects`)
	process.exit(1)
end
print(
	`sync-projects: {if check then "clean" else "done"} ({#projects} project(s), {#entries} module folder(s))`
)
