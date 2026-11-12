--!nocheck
--[[
	tools/make-migration <module-dir | ModuleName> [--name <label>] [--from <n>]
	Writes the module's next save migration, migrations/NNN_<label>.luau (NNN = data.version + 1),
	a test stub tests/MigrationNNN.spec.luau, and bumps data.version in module.luau (declaring
	`migrations = script.Parent.migrations` the first time). module-api.md §6,
	docs/framework/generators.md. Pure parts: MakeGen.luau (the generated text; MakeGen.spec.luau)
	and MakeMigration.luau (v1.7.1: version, bump, Rojo mapping; MakeMigration.spec.luau).
	A ModuleName is looked up in every game's modules/ (games/*, the core's examples, or the
	single-game project's root) and examples/modules/*.
	(v1.7.1) data.version may be a reference (`version = Save.VERSION`, a local): the definition is
	evaluated to read it and the literal it comes from is bumped; --from <n> gives the current
	version instead (a warning when it disagrees). A module inside a game must be mapped in the
	game's *.project.json: its node (ReplicatedStorage.Modules.<Name>, or the game module's
	ReplicatedStorage.GameModule) gets `migrations` unless a $path already covers the folder; a
	module the projects don't map is refused before anything is written.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local MakeGen = require("./MakeGen")

local USAGE =
	"usage: tools/make-migration <module-dir | ModuleName> [--name <label>] [--from <current data.version>]"

local target, label, from = nil, nil, nil
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
	elseif a == "--from" or string.sub(a, 1, 7) == "--from=" then
		local value = if a == "--from" then args[i + 1] else string.sub(a, 8)
		if a == "--from" then
			i += 1
		end
		local n, fromErr = require("./MakeMigration").parseFrom(value)
		if n == nil then
			print("error: " .. tostring(fromErr) .. "\n" .. USAGE)
			process.exit(1)
		end
		from = n
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

local MakeMigration = require("./MakeMigration")
local SyncProjects = require("./SyncProjects")
local luau = require("@lune/luau")

local function fail(message: string)
	print("error: " .. message)
	process.exit(1)
end

local modulePath = dir .. "/module.luau"
local source = fs.readFile(modulePath)

-- 1. the current data.version: a literal as written, otherwise the definition evaluated (v1.7.1);
-- --from <n> overrides both
local resolved, resolveErr = MakeMigration.resolveVersion(fs, luau, dir, source, from, MakeGen)
if resolved == nil then
	fail(tostring(resolveErr))
end
if resolved.warning then
	print("warning: " .. resolved.warning)
end

-- 2. the migration, the test stub and module.luau (planned, nothing written yet)
local existing = {}
if fs.isDir(dir .. "/migrations") then
	for _, entry in fs.readDir(dir .. "/migrations") do
		if string.match(entry, "%.luau$") then
			table.insert(existing, entry)
		end
	end
end
local plan, err = MakeGen.nextMigration(source, existing, label, dir, { from = resolved.version })
if plan == nil then
	fail(tostring(err))
end
local writes = { { path = modulePath, text = plan.module } }
local bumpNote = nil
if not plan.bumped then
	-- a referenced data.version (`Save.VERSION`, a local): bump the one literal it comes from
	local bump, bumpErr = MakeMigration.bumpReference(fs, luau, dir, plan.module, resolved.expr, plan.version)
	if bump and bump.path == modulePath then
		writes[1].text = bump.text
		bumpNote = "data.version (`" .. resolved.expr .. "`, set in module.luau)"
	elseif bump then
		table.insert(writes, bump)
		bumpNote = "data.version (`" .. resolved.expr .. "`, set in " .. bump.path .. ")"
	elseif from == nil then
		-- a computed version (`Base.VERSION + 1`): refuse rather than leave a migration whose
		-- version the module never reaches; --from <n> is the explicit opt-in to bump by hand
		fail(
			string.format(
				"data.version is `%s` and make-migration can't bump it (%s): nothing was written.\n"
					.. "Run again with --from %d to write the migration anyway, then set data.version to %d yourself",
				resolved.expr,
				tostring(bumpErr),
				resolved.version,
				plan.version
			)
		)
	else
		bumpNote = nil
		print(
			string.format(
				"warning: data.version is `%s` and make-migration couldn't bump it (%s): set it to %d yourself",
				resolved.expr,
				tostring(bumpErr),
				plan.version
			)
		)
	end
end

-- 3. the game's Rojo projects must carry migrations/ (a game module's ReplicatedStorage.GameModule
-- maps only module.luau): checked before anything is written, so an unmapped module fails clean
local gameDir, rel = MakeMigration.projectFor(dir)
local projects = {}
if gameDir then
	local prefix = if gameDir == "." then "" else gameDir .. "/"
	if fs.isDir(gameDir) then
		for _, entry in fs.readDir(gameDir) do
			if string.match(entry, "%.project%.json$") and fs.isFile(prefix .. entry) then
				table.insert(projects, prefix .. entry)
			end
		end
	end
	table.sort(projects)
end
local projectWrites, mapped, mappedAnywhere = {}, {}, false
for _, projectPath in projects do
	local newText, status = MakeMigration.mapMigrations(SyncProjects, fs.readFile(projectPath), rel)
	if status == "added" then
		table.insert(projectWrites, { path = projectPath, text = newText })
		table.insert(mapped, projectPath)
	end
	mappedAnywhere = mappedAnywhere or status ~= "unmapped"
end
if #projects > 0 and not mappedAnywhere then
	fail(
		string.format(
			"%s/module.luau isn't mapped in %s, so a migration would never reach the place. Map the module"
				.. " first, and next to its `module` entry add\n  %s\n(nothing was written)",
			dir,
			table.concat(projects, ", "),
			MakeMigration.mappingSnippet(rel :: string)
		)
	)
end

-- 4. write
fs.writeDir(dir .. "/migrations")
fs.writeDir(dir .. "/tests")
fs.writeFile(`{dir}/migrations/{plan.file}.luau`, plan.source)
fs.writeFile(`{dir}/tests/Migration{string.format("%03d", plan.version)}.spec.luau`, plan.spec)
for _, w in writes do
	fs.writeFile(w.path, w.text)
end
for _, w in projectWrites do
	fs.writeFile(w.path, w.text)
end
for _, projectPath in mapped do
	print("mapped " .. plan.name .. " migrations/ in " .. projectPath)
end
if #projects == 0 then
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
if plan.bumped or bumpNote then
	-- the bumped version, read back the way the game reads it
	local check = MakeMigration.resolveVersion(fs, luau, dir, fs.readFile(modulePath), nil, MakeGen)
	if check and check.version ~= plan.version then
		print(
			string.format(
				"warning: data.version now reads %d, not %d: check `%s`",
				check.version,
				plan.version,
				check.expr
			)
		)
	end
	print(
		"updated "
			.. (bumpNote or (dir .. "/module.luau: data.version"))
			.. " = "
			.. plan.version
			.. "; update data.default to the new shape too"
	)
end
print("next: tools/test " .. dir)
