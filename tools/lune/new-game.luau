--!nocheck
--[[
	tools/new-game <name> [--modules A,B,C] [--no-design-doc]
	Scaffold a new game from templates/new-game (a working copy of _sandbox).
	- copies the template to games/<name>
	- assigns the next free Rojo servePort (highest existing + 1, starting at 34872)
	- writes deploy.json with clearly marked placeholder ids (0, plus an `idsNote`); tools/publish
	  refuses them until the experiences exist on Roblox
	- sets the project name, servePort and GameConfig.gameId, and renames the game's own module
	  (templates/new-game/modules/sandbox -> modules/<name>, module + server part "<Name>",
	  ServerScriptService.Modules.<Name> in the project)
	- --modules: writes code and config for the listed modules only (names checked against the
	  kit module definitions, tools/lune/KitModules.luau; missing hard dependencies are added and
	  reported). Default: the template's list (all). It trims GameConfig.modules and the game
	  module's dependsOn, and resolves the template's module markers (`-- @if Economy` ...
	  `-- @end`, NewGame.applyMarkers) in every .luau file: the game module's server code,
	  Balance.luau sections, Items fields, products, events, tuning and the client's actions.
	  The markers are always stripped, so a generated game never carries them. Unused kit locals
	  are pruned, stylua formats the result, and the guardrails re-check it (lint passes with no
	  hand trimming; v1.3.0).
	- writes a README stub ("Status: scaffolded")
	- adds a row to GAMES.md (Core column "—" until the first tools/publish) and, unless
	  --no-design-doc, creates docs/games/<name>.md from templates/game-design.md
	Pure parts live in NewGame.luau (specs in NewGame.spec.luau).
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local KitModules = require("./KitModules")
local NewGame = require("./NewGame")
local ModuleDiscovery = require("./ModuleDiscovery")
local SyncProjects = require("./SyncProjects")
local Roots = require("./Roots")
local Layout = require("./Layout")

-- the template lives in the core (in a games repo: roblox-core/templates/new-game)
local TEMPLATE = Roots.core("templates/new-game")

local Modules = KitModules.load(fs)

local BASE_PORT = 34872

if NewGame.wantsHelp(process.args) then
	print(NewGame.HELP)
	process.exit(0)
end
local opts, argError = NewGame.parseArgs(process.args)
if opts == nil then
	print("error: " .. tostring(argError))
	process.exit(1)
end
local name = opts.name

local chosenModules = nil
if opts.modules then
	local order, added, errors = NewGame.resolveModules(Modules, opts.modules)
	if order == nil then
		print("error: --modules:")
		for _, e in errors do
			print("  - " .. e)
		end
		process.exit(1)
	end
	for _, note in added do
		print("note: added dependency " .. note)
	end
	chosenModules = order
end

-- (v1.5.0) single-game project (tools/new-project; Roots.single): the game is the project root
local atRoot = Roots.single
local target = if atRoot then "." else opts.into .. "/" .. name
-- a path inside the new game (no "./" prefix at the root)
local function at(rel: string): string
	return if target == "." then rel else target .. "/" .. rel
end
if atRoot then
	if opts.into ~= "games" then
		print("error: --into does not apply in a single-game project (the game is the project root)")
		process.exit(1)
	end
	if fs.isFile("default.project.json") or fs.isDir("src") or fs.isDir("modules/" .. name) then
		print("error: the project root already has a game (default.project.json / src/)")
		process.exit(1)
	end
elseif fs.isDir(target) then
	print("error: " .. target .. " already exists")
	process.exit(1)
end
if not fs.isDir(TEMPLATE) then
	print("error: " .. TEMPLATE .. " is missing")
	process.exit(1)
end

-- next free port (deploy.json and every *.project.json of every game, e.g. sandbox/foundation-only)
local highest = BASE_PORT - 1
local function consider(path: string)
	local ok, json = pcall(serde.decode, "json", fs.readFile(path))
	if ok and type(json) == "table" and type(json.servePort) == "number" and json.servePort > highest then
		highest = json.servePort
	end
end
for _, dir in Roots.gameDirs(fs) do
	for _, file in fs.readDir(dir) do
		if file == "deploy.json" or string.match(file, "%.project%.json$") then
			consider(dir .. "/" .. file)
		end
	end
end
local port = highest + 1

-- copy (skip spec-free artefacts? copy everything; the template is meant to be complete)
local function copyDir(src: string, dst: string)
	fs.writeDir(dst)
	for _, entry in fs.readDir(src) do
		local s = src .. "/" .. entry
		local d = dst .. "/" .. entry
		if fs.isDir(s) then
			copyDir(s, d)
		elseif entry ~= ".DS_Store" then
			fs.writeFile(d, fs.readFile(s))
		end
	end
end
if not atRoot and not fs.isDir(opts.into) then
	fs.writeDir(opts.into)
end
copyDir(TEMPLATE, target)

-- module markers: keep only the chosen modules' code in every .luau file (all when no --modules)
local chosenSet: { [string]: boolean } = {}
for _, n in chosenModules or Modules.ORDER do
	chosenSet[n] = true
end
local function luauFiles(dir: string, out: { string })
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			luauFiles(path, out)
		elseif string.match(entry, "%.luau$") then
			table.insert(out, path)
		end
	end
end
local files: { string } = {}
if atRoot then
	-- never the studwork/ submodule: only what the template copied
	luauFiles("src", files)
	luauFiles("modules", files)
else
	luauFiles(target, files)
end
table.sort(files)
for _, path in files do
	local source = fs.readFile(path)
	if string.find(source, "-- @", 1, true) then
		local out, markerError = NewGame.applyMarkers(source, chosenSet)
		if out == nil then
			print("error: " .. tostring(markerError) .. " (" .. path .. ")")
			if not atRoot then
				fs.removeDir(target)
			end
			process.exit(1)
		end
		fs.writeFile(path, NewGame.pruneKitLocals(out :: string))
	end
end

-- the game's own module: modules/sandbox -> modules/<name>, "Sandbox" -> "<Name>"
local moduleName = NewGame.moduleName(name)
local TEMPLATE_MODULE = "Sandbox"
local moduleDir = at("modules/") .. name
fs.move(at("modules/sandbox"), moduleDir)
-- the console prefix / log tag in the server part is the module's lower-case name (item: a
-- generated game's help text must say the command a player really types)
local serverPath = moduleDir .. "/server/init.luau"
fs.writeFile(serverPath, NewGame.renameConsolePrefix(fs.readFile(serverPath), moduleName))
local modulePath = moduleDir .. "/module.luau"
local moduleSource = fs.readFile(modulePath)
local renamedModule, renames =
	string.gsub(moduleSource, '"' .. TEMPLATE_MODULE .. '"', '"' .. moduleName .. '"')
if renames ~= 2 then
	print('error: expected name and server = "' .. TEMPLATE_MODULE .. '" in ' .. modulePath)
	process.exit(1)
end

-- project file
local projectPath = at("default.project.json")
-- order-preserving JSON (tools/sync-projects), so the project keeps the template's layout and its
-- generated kit module entries (v1.3.1 R19); only the game module's entries change
local project = SyncProjects.decode(fs.readFile(projectPath))
project.vals.name = name
project.vals.servePort = port
local tree = project.vals.tree
-- $paths that leave the template (../../packages/..., ../../deps/...) point into the core: rewrite
-- them relative to the new game (identical in the core repo; ../../roblox-core/... in a games repo)
local function repoint(node: any)
	if type(node) ~= "table" or not node.__object then
		return
	end
	local p = node.vals["$path"]
	if type(p) == "string" and string.sub(p, 1, 3) == "../" then
		local corePath = Layout.normalize("templates/new-game/" .. p)
		node.vals["$path"] = SyncProjects.relative(target, Roots.core(corePath))
	end
	for _, key in node.keys do
		if string.sub(key, 1, 1) ~= "$" then
			repoint(node.vals[key])
		end
	end
end
repoint(tree)
tree.vals.ReplicatedStorage.vals.GameModule.vals.module.vals["$path"] = "modules/" .. name .. "/module.luau"
local sssModules = tree.vals.ServerScriptService.vals.Modules
local rebuilt = SyncProjects.newObject()
for _, key in sssModules.keys do
	-- the template's own game module (templates/new-game/modules/sandbox) is replaced
	local value = sssModules.vals[key]
	local p = type(value) == "table" and value.vals and value.vals["$path"]
	if not (type(p) == "string" and string.match(p, "^modules/")) then
		SyncProjects.set(rebuilt, key, value)
	end
end
local own = SyncProjects.newObject()
SyncProjects.set(own, "$path", "modules/" .. name .. "/server")
SyncProjects.set(rebuilt, moduleName, own)
tree.vals.ServerScriptService.vals.Modules = rebuilt
-- the generated module entries in their canonical place (tools/sync-projects --check stays clean)
local synced = SyncProjects.sync(
	projectPath,
	SyncProjects.encode(project),
	ModuleDiscovery.discover(fs, require("./Roots").CORE)
)
fs.writeFile(projectPath, synced)

-- deploy.json
fs.writeFile(at("deploy.json"), serde.encode("json", NewGame.deployJson(name, port), true) .. "\n")

-- gameId in the config
local configPath = at("src/shared/Config/init.luau")
local config = fs.readFile(configPath)
local replaced, count = string.gsub(config, 'gameId = "[^"]*"', 'gameId = "' .. name .. '"', 1)
if count ~= 1 then
	print("error: could not find gameId in " .. configPath)
	process.exit(1)
end
if chosenModules then
	local rewritten, rewriteError = NewGame.rewriteModulesBlock(replaced, chosenModules)
	if rewritten == nil then
		print("error: " .. tostring(rewriteError) .. " (" .. configPath .. ")")
		process.exit(1)
	end
	replaced = NewGame.pruneKitLocals(rewritten)
	local trimmed, trimError = NewGame.trimDependsOn(renamedModule, chosenModules)
	if trimmed == nil then
		print("error: " .. tostring(trimError) .. " (" .. modulePath .. ")")
		process.exit(1)
	end
	renamedModule = NewGame.pruneKitLocals(trimmed)
end
fs.writeFile(configPath, replaced)
fs.writeFile(modulePath, renamedModule)

-- the game's specs: its own module name, its project path, its module list
local specPath = at("src/shared/Config.spec.luau")
if fs.isFile(specPath) then
	local spec = string.gsub(
		fs.readFile(specPath),
		'name = "' .. TEMPLATE_MODULE .. '"',
		'name = "' .. moduleName .. '"'
	)
	fs.writeFile(specPath, spec)
end
local bootPath = at("src/server/Boot.spec.luau")
if fs.isFile(bootPath) then
	local boot = fs.readFile(bootPath)
	boot = string.gsub(boot, "templates/new%-game/default%.project%.json", at("default.project.json"))
	boot = string.gsub(boot, 'describe%("templates/new%-game boot"', 'describe("' .. name .. ' boot"')
	boot = string.gsub(boot, "the template's real Config", name .. "'s real Config")
	boot = string.gsub(boot, '"' .. TEMPLATE_MODULE .. '", %-%-', '"' .. moduleName .. '", --')
	if chosenModules then
		local keep = { [moduleName] = true }
		for _, n in chosenModules do
			keep[n] = true
		end
		local lines = {}
		for line in string.gmatch(boot .. "\n", "([^\n]*)\n") do
			local listed = string.match(line, '^\t"([%w_]+)",')
			if listed == nil or keep[listed] then
				table.insert(lines, line)
			end
		end
		boot = table.concat(lines, "\n")
	end
	fs.writeFile(bootPath, boot)
end

-- README (a single-game project's README comes from templates/single-game, tools/new-project)
if not atRoot then
	fs.writeFile(at("README.md"), NewGame.readme(name, port, opts.designDoc, chosenModules))
end

-- design doc (single-game project: docs/design.md)
local docPath = if atRoot then "docs/design.md" else "docs/games/" .. name .. ".md"
local designTemplate = Roots.core("templates/game-design.md")
if opts.designDoc and not fs.isFile(docPath) and fs.isFile(designTemplate) then
	if not fs.isDir("docs") then
		fs.writeDir("docs")
	end
	if not atRoot and not fs.isDir("docs/games") then
		fs.writeDir("docs/games")
	end
	local doc = string.gsub(fs.readFile(designTemplate), "{{name}}", name)
	fs.writeFile(docPath, doc)
end

-- GAMES.md row (the games repo's game list; skipped when the project has none, e.g. the core repo)
if fs.isFile("GAMES.md") then
	local games = fs.readFile("GAMES.md")
	local docCell = if opts.designDoc
		then string.format("[docs/games/%s.md](docs/games/%s.md)", name, name)
		else "—"
	local row = string.format("| %s | scaffolded | %d | 0 | 0 | 0 | — | %s |\n", name, port, docCell)
	if not string.find(games, "| " .. name .. " |", 1, true) then
		if string.sub(games, -1) ~= "\n" then
			games ..= "\n"
		end
		fs.writeFile("GAMES.md", games .. row)
	end
end

print(
	string.format(
		"created %s (servePort %d). Next: fill src/shared/Config, then tools/dev %s",
		target,
		port,
		name
	)
)

-- Format what the markers left (stylua is part of the toolchain; skipped if it isn't installed).
local formatArgs = { "--config-path", Roots.core("stylua.toml") }
if atRoot then
	-- never the studwork/ submodule: only the game's own folders
	table.insert(formatArgs, "src")
	table.insert(formatArgs, "modules")
else
	table.insert(formatArgs, target)
end
local okFormat, formatResult = pcall(process.exec, "stylua", formatArgs)
if not okFormat or not formatResult.ok then
	print("note: stylua did not run on " .. target .. "; run `stylua " .. target .. "` before tools/lint")
end

-- The generated game must pass the guardrails as written. If it doesn't, the template's markers
-- missed something: say so now (tools/lint would fail on it later).
local result = process.exec("lune", { "run", Roots.core("tools/lune/guardrails"), target })
if not result.ok then
	print("warning: the generated game fails the guardrails (a template marker is missing; please report")
	print("         it). Run `lune run tools/lune/guardrails " .. target .. "`:")
	local shown = 0
	for line in string.gmatch(result.stdout, "[^\n]+") do
		if string.find(line, ": [", 1, true) and shown < 5 then
			print("  " .. line)
			shown += 1
		end
	end
end
