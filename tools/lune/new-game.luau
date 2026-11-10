--!nocheck
--[[
	tools/new-game <name>: scaffold a new game from templates/new-game (a working copy of _sandbox).
	- copies the template to games/<name>
	- assigns the next free Rojo servePort (highest existing + 1, starting at 34872)
	- writes deploy.json (place/universe ids 0 until the experience exists on Roblox)
	- sets the project name, servePort and GameConfig.gameId
	- adds a row to GAMES.md (Core column "—" until the first tools/publish) and creates
	  docs/games/<name>.md from templates/game-design.md
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local BASE_PORT = 34872

local name = process.args[1]
if name == nil or not string.match(name, "^[a-z][a-z0-9%-]+$") or #name > 32 then
	print("usage: tools/new-game <name>   (lowercase letters, digits, dashes; 2-32 chars)")
	process.exit(1)
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

-- next free port
local highest = BASE_PORT - 1
for _, entry in fs.readDir("games") do
	local deployPath = "games/" .. entry .. "/deploy.json"
	if fs.isFile(deployPath) then
		local ok, deploy = pcall(serde.decode, "json", fs.readFile(deployPath))
		if ok and type(deploy.servePort) == "number" and deploy.servePort > highest then
			highest = deploy.servePort
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

-- project file
local projectPath = target .. "/default.project.json"
local project = serde.decode("json", fs.readFile(projectPath))
project.name = name
project.servePort = port
fs.writeFile(projectPath, serde.encode("json", project, true) .. "\n")

-- deploy.json
local deploy = {
	name = name,
	servePort = port,
	test = { universeId = 0, placeId = 0 },
	live = { universeId = 0, placeId = 0 },
}
fs.writeFile(target .. "/deploy.json", serde.encode("json", deploy, true) .. "\n")

-- gameId in the config
local configPath = target .. "/src/shared/Config/init.luau"
local config = fs.readFile(configPath)
local replaced, count = string.gsub(config, 'gameId = "[^"]*"', 'gameId = "' .. name .. '"', 1)
if count ~= 1 then
	print("error: could not find gameId in " .. configPath)
	process.exit(1)
end
fs.writeFile(configPath, replaced)

-- README
fs.writeFile(
	target .. "/README.md",
	"# "
		.. name
		.. "\n\n- Design doc: [docs/games/"
		.. name
		.. ".md](../../docs/games/"
		.. name
		.. ".md)\n"
		.. "- Status: scaffolded from templates/new-game\n- Rojo: `rojo serve games/"
		.. name
		.. "/default.project.json` (port "
		.. port
		.. ")\n"
)

-- design doc
local docPath = "docs/games/" .. name .. ".md"
if not fs.isFile(docPath) and fs.isFile("templates/game-design.md") then
	fs.writeDir("docs/games")
	local doc = string.gsub(fs.readFile("templates/game-design.md"), "{{name}}", name)
	fs.writeFile(docPath, doc)
end

-- GAMES.md row
local games = fs.readFile("GAMES.md")
local row = string.format(
	"| %s | scaffolded | %d | 0 | 0 | 0 | — | [docs/games/%s.md](docs/games/%s.md) |\n",
	name,
	port,
	name,
	name
)
if not string.find(games, "| " .. name .. " |", 1, true) then
	if string.sub(games, -1) ~= "\n" then
		games ..= "\n"
	end
	fs.writeFile("GAMES.md", games .. row)
end

print(
	string.format(
		"created %s (servePort %d). Next: fill src/shared/Config, then rojo serve %s",
		target,
		port,
		projectPath
	)
)
