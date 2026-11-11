--!nocheck
--[[
	tools/make-module <Name> (--game <game> | --dir <path>)
	A new StudWork module skeleton (module-api.md §1) with a passing harness test. Pure parts:
	MakeGen.luau (self-test: MakeGen.spec.luau).
	  --game <game>  writes games/<game>/modules/<name-kebab>/ and maps it in that game's
	                 default.project.json (ReplicatedStorage.Modules.<Name>, ServerScriptService.Modules.<Name>)
	  --dir <path>   writes <path>/ only (a module outside a game, e.g. examples/modules/<name>)
	Prints the GameConfig.modules line to add and the test command.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local MakeGen = require("./MakeGen")

local USAGE = "usage: tools/make-module <Name> (--game <game> | --dir <path>)"

local name, game, dir = nil, nil, nil
local args = process.args
local i = 1
while i <= #args do
	local a = args[i]
	if a == "--game" then
		game = args[i + 1]
		i += 1
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
if name == nil or (game == nil) == (dir == nil) then
	print(USAGE)
	process.exit(1)
end

local projectPath = nil
if game then
	projectPath = "games/" .. game .. "/default.project.json"
	if not fs.isFile(projectPath) then
		print("error: no such game: " .. game .. " (" .. projectPath .. ")")
		process.exit(1)
	end
	dir = "games/" .. game .. "/modules/" .. MakeGen.kebab(name)
end
dir = string.gsub(dir, "/+$", "")

local files, err = MakeGen.writeModule(fs, name, dir)
if files == nil then
	print("error: " .. tostring(err))
	process.exit(1)
end
print("created " .. dir .. "/ (module.luau, server/, client/, tests/, README.md)")

if projectPath then
	local project = serde.decode("json", fs.readFile(projectPath))
	MakeGen.addToProject(project, name, "modules/" .. MakeGen.kebab(name))
	fs.writeFile(projectPath, serde.encode("json", project, true) .. "\n")
	print("mapped " .. name .. " in " .. projectPath)
end

pcall(process.exec, "stylua", { dir })

print("next:")
print("  1. list it in GameConfig.modules (src/shared/Config/init.luau):")
print('       local GameModules = ReplicatedStorage:WaitForChild("Modules")   -- once, at the top')
print("       " .. MakeGen.configLine(name))
print("  2. tools/test " .. dir)
