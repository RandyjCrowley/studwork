--!nocheck
--[[
	tools/make-migration <module-dir | ModuleName> [--name <label>]
	Writes the module's next save migration, migrations/NNN_<label>.luau (NNN = data.version + 1),
	a test stub tests/MigrationNNN.spec.luau, and bumps data.version in module.luau (declaring
	`migrations = script.Parent.migrations` the first time). module-api.md §6. Pure parts:
	MakeGen.luau (self-test: MakeGen.spec.luau).
	A ModuleName is looked up in games/*/modules/*/module.luau and examples/modules/*/module.luau.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local MakeGen = require("./MakeGen")

local USAGE = "usage: tools/make-migration <module-dir | ModuleName> [--name <label>]"

local target, label = nil, nil
local args = process.args
local i = 1
while i <= #args do
	local a = args[i]
	if a == "--help" or a == "-h" then
		print(USAGE)
		process.exit(0)
	end
	if a == "--name" then
		label = args[i + 1]
		i += 1
	elseif string.sub(a, 1, 2) == "--" then
		print("error: unknown option " .. a .. "\n" .. USAGE)
		process.exit(1)
	elseif target == nil then
		target = a
	else
		print("error: unexpected argument " .. a .. "\n" .. USAGE)
		process.exit(1)
	end
	i += 1
end
if target == nil then
	print(USAGE)
	process.exit(1)
end

local dir = string.gsub(target, "/+$", "")
if not fs.isFile(dir .. "/module.luau") then
	-- a module name: search the usual module folders
	local found = {}
	local function scan(root: string)
		if not fs.isDir(root) then
			return
		end
		for _, entry in fs.readDir(root) do
			local candidate = root .. "/" .. entry
			local path = candidate .. "/module.luau"
			if
				fs.isFile(path) and string.find(fs.readFile(path), '\n\tname = "' .. target .. '"', 1, true)
			then
				table.insert(found, candidate)
			end
		end
	end
	for _, g in require("./Roots").gameDirs(fs) do
		scan(g .. "/modules")
	end
	scan("examples/modules")
	if #found ~= 1 then
		print(
			"error: "
				.. (if #found == 0
					then "no module.luau for '" .. target .. "'"
					else "'" .. target .. "' is ambiguous: " .. table.concat(found, ", "))
				.. "; pass the module folder"
		)
		process.exit(1)
	end
	dir = found[1]
end

local plan, err = MakeGen.writeMigration(fs, dir, label)
if plan == nil then
	print("error: " .. tostring(err))
	process.exit(1)
end
-- a module inside a game: make sure its Rojo mapping carries the migrations folder
local gameDir, folder = string.match(dir, "^(.+)/modules/([^/]+)$")
if gameDir and not fs.isFile(gameDir .. "/default.project.json") then
	gameDir = nil
end
if gameDir then
	-- order-preserving JSON (tools/sync-projects), so lint's sync-projects --check stays clean
	local SyncProjects = require("./SyncProjects")
	local projectPath = gameDir .. "/default.project.json"
	local project = SyncProjects.decode(fs.readFile(projectPath))
	local rs = project.vals.tree.vals.ReplicatedStorage
	local rsModules = rs and rs.vals.Modules
	local entry = rsModules and rsModules.vals[plan.name]
	if entry and entry.vals.migrations == nil then
		local node = SyncProjects.newObject()
		SyncProjects.set(node, "$path", "modules/" .. folder .. "/migrations")
		SyncProjects.set(entry, "migrations", node)
		fs.writeFile(projectPath, SyncProjects.encode(project))
		print("mapped " .. plan.name .. ".migrations in " .. projectPath)
	elseif entry == nil then
		print(
			"note: "
				.. plan.name
				.. " isn't mapped under ReplicatedStorage.Modules in "
				.. projectPath
				.. "; map migrations/ next to module.luau"
		)
	end
else
	print(
		"note: map "
			.. dir
			.. "/migrations next to module.luau in your Rojo project (ReplicatedStorage.Modules.<Name>.migrations)"
	)
end
pcall(process.exec, "stylua", { "--config-path", require("./Roots").core("stylua.toml"), dir })
print(
	string.format(
		"created %s/migrations/%s.luau (data.version %d -> %d)",
		dir,
		plan.file,
		plan.version - 1,
		plan.version
	)
)
print(
	string.format(
		"created %s/tests/Migration%03d.spec.luau (fill in a real version %d section)",
		dir,
		plan.version,
		plan.version - 1
	)
)
print(
	"updated "
		.. dir
		.. "/module.luau: data.version = "
		.. plan.version
		.. "; update data.default to the new shape too"
)
print("next: tools/test " .. dir)
