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
	for _, g in fs.readDir("games") do
		scan("games/" .. g .. "/modules")
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
local gameName, folder = string.match(dir, "^games/([^/]+)/modules/([^/]+)$")
if gameName then
	local serde = require("@lune/serde")
	local projectPath = "games/" .. gameName .. "/default.project.json"
	local project = serde.decode("json", fs.readFile(projectPath))
	local rsModules = project.tree.ReplicatedStorage and project.tree.ReplicatedStorage.Modules
	local entry = rsModules and rsModules[plan.name]
	if entry and entry.migrations == nil then
		entry.migrations = { ["$path"] = "modules/" .. folder .. "/migrations" }
		fs.writeFile(projectPath, serde.encode("json", project, true) .. "\n")
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
pcall(process.exec, "stylua", { dir })
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
