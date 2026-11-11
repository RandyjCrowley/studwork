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
	- --modules: trims GameConfig.modules and the game module's dependsOn to that list (names
	  checked against the kit module definitions, tools/lune/KitModules.luau; missing hard
	  dependencies are added and reported). Default: the template's list (all). The template's
	  game code is NOT trimmed: a warning lists what still uses a dropped module (the full
	  `--modules` generator is core-v1.3.0 Phase 1 agent E's).
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

local Modules = KitModules.load(fs)

local BASE_PORT = 34872

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

local target = "games/" .. name
if fs.isDir(target) then
	print("error: " .. target .. " already exists")
	process.exit(1)
end
if not fs.isDir("templates/new-game") then
	print("error: templates/new-game is missing")
	process.exit(1)
end

-- next free port (deploy.json and every *.project.json, e.g. _sandbox/foundation-only)
local highest = BASE_PORT - 1
local function consider(path: string)
	local ok, json = pcall(serde.decode, "json", fs.readFile(path))
	if ok and type(json) == "table" and type(json.servePort) == "number" and json.servePort > highest then
		highest = json.servePort
	end
end
for _, entry in fs.readDir("games") do
	local dir = "games/" .. entry
	if fs.isDir(dir) then
		for _, file in fs.readDir(dir) do
			if file == "deploy.json" or string.match(file, "%.project%.json$") then
				consider(dir .. "/" .. file)
			end
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
copyDir("templates/new-game", target)

-- the game's own module: modules/sandbox -> modules/<name>, "Sandbox" -> "<Name>"
local moduleName = NewGame.moduleName(name)
local TEMPLATE_MODULE = "Sandbox"
local moduleDir = target .. "/modules/" .. name
fs.move(target .. "/modules/sandbox", moduleDir)
local modulePath = moduleDir .. "/module.luau"
local moduleSource = fs.readFile(modulePath)
local renamedModule, renames =
	string.gsub(moduleSource, '"' .. TEMPLATE_MODULE .. '"', '"' .. moduleName .. '"')
if renames ~= 2 then
	print('error: expected name and server = "' .. TEMPLATE_MODULE .. '" in ' .. modulePath)
	process.exit(1)
end

-- project file
local projectPath = target .. "/default.project.json"
local project = serde.decode("json", fs.readFile(projectPath))
project.name = name
project.servePort = port
local tree = project.tree
tree.ReplicatedStorage.GameModule.module["$path"] = "modules/" .. name .. "/module.luau"
tree.ServerScriptService.Modules = {
	["$className"] = "Folder",
	[moduleName] = { ["$path"] = "modules/" .. name .. "/server" },
}
fs.writeFile(projectPath, serde.encode("json", project, true) .. "\n")

-- deploy.json
fs.writeFile(target .. "/deploy.json", serde.encode("json", NewGame.deployJson(name, port), true) .. "\n")

-- gameId in the config
local configPath = target .. "/src/shared/Config/init.luau"
local config = fs.readFile(configPath)
local replaced, count = string.gsub(config, 'gameId = "[^"]*"', 'gameId = "' .. name .. '"', 1)
if count ~= 1 then
	print("error: could not find gameId in " .. configPath)
	process.exit(1)
end
if chosenModules then
	local rewritten, rewriteError = NewGame.rewriteModulesBlock(replaced, chosenModules, Modules.kitFolder)
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
local specPath = target .. "/src/shared/Config.spec.luau"
if fs.isFile(specPath) then
	local spec = string.gsub(
		fs.readFile(specPath),
		'name = "' .. TEMPLATE_MODULE .. '"',
		'name = "' .. moduleName .. '"'
	)
	fs.writeFile(specPath, spec)
end
local bootPath = target .. "/src/server/Boot.spec.luau"
if fs.isFile(bootPath) then
	local boot = fs.readFile(bootPath)
	boot = string.gsub(boot, "templates/new%-game/default%.project%.json", target .. "/default.project.json")
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

-- README
fs.writeFile(target .. "/README.md", NewGame.readme(name, port, opts.designDoc, chosenModules))

-- design doc
local docPath = "docs/games/" .. name .. ".md"
if opts.designDoc and not fs.isFile(docPath) and fs.isFile("templates/game-design.md") then
	fs.writeDir("docs/games")
	local doc = string.gsub(fs.readFile("templates/game-design.md"), "{{name}}", name)
	fs.writeFile(docPath, doc)
end

-- GAMES.md row
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

print(
	string.format(
		"created %s (servePort %d). Next: fill src/shared/Config, then tools/dev %s",
		target,
		port,
		name
	)
)

-- With a module subset the template's sandbox code may still call dropped modules: say so now
-- (tools/lint would fail on it later).
if chosenModules then
	local result = process.exec("lune", { "run", "tools/lune/guardrails", target })
	if not result.ok then
		print("warning: the template code still uses modules you left out (tools/lint will fail until")
		print("         you replace or trim it; run `lune run tools/lune/guardrails " .. target .. "`):")
		local shown = 0
		for line in string.gmatch(result.stdout, "[^\n]+") do
			if string.find(line, "[modules]", 1, true) and shown < 5 then
				print("  " .. line)
				shown += 1
			end
		end
	end
end
