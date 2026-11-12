--!nocheck
--[[
	tools/make-module <Name> (--game <game> | --dir <path>)
	A new StudWork module skeleton (module-api.md §1) with a passing harness test. Pure parts:
	MakeGen.luau (self-test: MakeGen.spec.luau).
	  --game <game>  writes games/<game>/modules/<name-kebab>/ and maps it in that game's
	                 default.project.json (ReplicatedStorage.Modules.<Name>, ServerScriptService.Modules.<Name>)
	  --dir <path>   writes <path>/ only (a module outside a game, e.g. examples/modules/<name>)
	  (neither)      (v1.5.0) single-game project: the root game (modules/<name-kebab>/)
	  --net          also writes net.blink (the module's own messages; then run tools/net)
	Prints the GameConfig.modules line to add and the test command.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local MakeGen = require("./MakeGen")
local ModuleDiscovery = require("./ModuleDiscovery")
local SyncProjects = require("./SyncProjects")

local USAGE = "usage: tools/make-module <Name> (--game <game> | --dir <path>) [--net]"
	.. "  (single-game project: tools/make-module <Name> [--net])"

local name, game, dir = nil, nil, nil
local withNet = false
local args = process.args
local i = 1
while i <= #args do
	local a = args[i]
	if a == "--help" or a == "-h" then
		print(USAGE)
		process.exit(0)
	end
	if a == "--game" then
		game = args[i + 1]
		i += 1
	elseif a == "--net" then
		withNet = true
	elseif a == "--dir" then
		dir = args[i + 1]
		i += 1
	elseif string.sub(a, 1, 2) == "--" then
		print("error: unknown option " .. a .. "\n" .. USAGE)
		process.exit(1)
	elseif name == nil then
		name = a
	else
		print("error: unexpected argument " .. a .. "\n" .. USAGE)
		process.exit(1)
	end
	i += 1
end
-- (v1.5.0) single-game project: the root game is the default (tools/make-module <Name>)
local Roots = require("./Roots")
if Roots.single and game == nil and dir == nil then
	game = "."
end
if name == nil or (game == nil) == (dir == nil) then
	print(USAGE)
	process.exit(1)
end

local projectPath = nil
if game then
	-- games/<game> (or, in the core repo, examples/<game> / examples/overrides/<game>; Roots.luau)
	local gameDir = Roots.findGame(fs, game)
	projectPath = if gameDir == "."
		then "default.project.json"
		else (gameDir or ("games/" .. game)) .. "/default.project.json"
	if gameDir == nil or not fs.isFile(projectPath) then
		print("error: no such game: " .. game .. " (" .. projectPath .. ")")
		process.exit(1)
	end
	dir = (if gameDir == "." then "" else gameDir .. "/") .. "modules/" .. MakeGen.kebab(name)
end
dir = string.gsub(dir, "/+$", "")

local files, err = MakeGen.writeModule(fs, name, dir, { net = withNet })
if files == nil then
	print("error: " .. tostring(err))
	process.exit(1)
end
print(
	"created "
		.. dir
		.. "/ (module.luau, server/, client/, tests/, README.md"
		.. (if withNet then ", net.blink" else "")
		.. ")"
)

if projectPath then
	-- the order-preserving JSON of tools/sync-projects, so the project keeps its layout (and
	-- `tools/sync-projects --check` in lint stays clean)
	local plain = { tree = { ReplicatedStorage = {}, ServerScriptService = {} } }
	MakeGen.addToProject(plain, name, "modules/" .. MakeGen.kebab(name))
	local project = SyncProjects.decode(fs.readFile(projectPath))
	for _, serviceName in { "ReplicatedStorage", "ServerScriptService" } do
		local service = project.vals.tree.vals[serviceName]
		if service == nil then
			service = SyncProjects.newObject()
			SyncProjects.set(project.vals.tree, serviceName, service)
		end
		local modules = service.vals.Modules
		if modules == nil then
			modules = SyncProjects.newObject()
			SyncProjects.set(modules, "$className", "Folder")
			SyncProjects.set(service, "Modules", modules)
		end
		SyncProjects.set(modules, name, SyncProjects.toOrdered(plain.tree[serviceName].Modules[name]))
	end
	-- the generated module entries stay in their canonical place (sync-projects --check)
	local synced = SyncProjects.sync(
		projectPath,
		SyncProjects.encode(project),
		ModuleDiscovery.discover(fs, require("./Roots").CORE)
	)
	fs.writeFile(projectPath, synced)
	print("mapped " .. name .. " in " .. projectPath)
end

pcall(process.exec, "stylua", { "--config-path", require("./Roots").core("stylua.toml"), dir })

print("next:")
print("  1. list it in GameConfig.modules (src/shared/Config/init.luau):")
print('       local GameModules = ReplicatedStorage:WaitForChild("Modules")   -- once, at the top')
print("       " .. MakeGen.configLine(name))
print("  2. tools/test " .. dir)
if withNet then
	print("  3. tools/net (compiles net.blink into server/Net.luau + client/Net.luau)")
end
