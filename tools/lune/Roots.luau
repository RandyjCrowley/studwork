--!nocheck
--[[
	tools/lune/Roots: where the core (this repo) and the project being worked on live (StudWork
	v1.4.0, docs/framework/games-repo.md). Every Lune tool runs with the PROJECT root as its working
	directory and reaches core files through Roots.core(path).

	Two modes, chosen by tools/_common.sh (which exports both variables):
	  core mode        STUDWORK_CORE_DIR unset or "."   the project IS the core repo (examples/,
	                                                    templates/, packages/ all at the root)
	  games-repo mode  STUDWORK_CORE_DIR = "roblox-core" the project is a games repo; the core is
	                                                    its git submodule at that (relative) path
	STUDWORK_CORE_DIR is always RELATIVE to the project root (no absolute paths end up in project
	files: Rojo `$path`s are computed from it).

	Roots.CORE                        "." or the relative core folder, e.g. "roblox-core"
	Roots.external                    true in games-repo mode
	Roots.core(path) -> string        a core-relative path as seen from the project root
	Roots.prefix(dir, path) -> string pure version of Roots.core (for specs)
	Roots.GAME_PARENTS                folders whose children may be games (`games`, and in core mode
	                                  `examples`, `examples/overrides`)
	Roots.gameDirs(fs) -> { string }  every game folder of the project (has default.project.json and
	                                  src/), sorted
	Roots.findGame(fs, nameOrPath) -> string?   games/<n>, examples/<n>, examples/overrides/<n> or
	                                  a folder path

	(added in v1.5.0, docs/framework/single-game-project.md) a third layout:
	  single-game mode  STUDWORK_LAYOUT = "single-game" (tools/_common.sh) or, without it, an
	                    external core plus the committed marker studwork.json at the project root
	                    with { "layout": "single-game" }: the project root IS the game and the core
	                    is its studwork/ submodule
	Roots.LAYOUT                      "core" | "games-repo" | "single-game"
	Roots.single                      true in single-game mode (Roots.external is true too)
	Roots.MARKER                      "studwork.json"
	Roots.layoutOf(coreDir, envLayout?, fs?) -> string   pure layout decision (specs)
	Roots.isSingleMarker(text) -> boolean   the marker file's text says single-game
	Roots.rootName(fs) -> string?     single-game mode: the root game's deploy.json name
	Roots.parentsFor(layout) -> { string }   GAME_PARENTS of a layout
	gameDirs(fs, layout?) / findGame(fs, name, layout?): `layout` overrides Roots.LAYOUT (specs)
	In single-game mode GAME_PARENTS is empty, gameDirs returns { "." } (when the root has
	default.project.json and src/) and findGame returns "." for nil, "", "." or the root game's
	name.
]]

local Roots = {}

local function clean(dir: string?): string
	if dir == nil or dir == "" or dir == "." or dir == "./" then
		return "."
	end
	local out = string.gsub(dir, "/+$", "")
	out = string.gsub(out, "^%./", "")
	return out
end

function Roots.prefix(dir: string?, path: string): string
	local d = clean(dir)
	if d == "." then
		return path
	end
	return d .. "/" .. path
end

local env = {}
do
	local ok, process = pcall(require, "@lune/process")
	if ok and type(process) == "table" then
		env = process.env
	end
end

Roots.CORE = clean(env.STUDWORK_CORE_DIR)
Roots.external = Roots.CORE ~= "."

Roots.MARKER = "studwork.json"

function Roots.isSingleMarker(text: string?): boolean
	return type(text) == "string" and string.find(text, '"layout"%s*:%s*"single%-game"') ~= nil
end

-- core | games-repo | single-game. tools/_common.sh exports its decision (STUDWORK_LAYOUT); without
-- it (a Lune tool run directly) the marker file decides, exactly like _common.sh does.
function Roots.layoutOf(coreDir: string?, envLayout: string?, fsLib: any?): string
	if clean(coreDir) == "." then
		return "core"
	end
	if envLayout == "single-game" or envLayout == "games-repo" then
		return envLayout
	end
	if fsLib and fsLib.isFile(Roots.MARKER) and Roots.isSingleMarker(fsLib.readFile(Roots.MARKER)) then
		return "single-game"
	end
	return "games-repo"
end

local fsModule = nil
do
	local ok, lfs = pcall(require, "@lune/fs")
	if ok and type(lfs) == "table" then
		fsModule = lfs
	end
end
Roots.LAYOUT = Roots.layoutOf(Roots.CORE, env.STUDWORK_LAYOUT, fsModule)
Roots.single = Roots.LAYOUT == "single-game"

function Roots.core(path: string): string
	return Roots.prefix(Roots.CORE, path)
end

-- (v1.5.0) the folders whose children may be games, for a layout
function Roots.parentsFor(layout: string): { string }
	if layout == "single-game" then
		return {}
	elseif layout == "games-repo" then
		return { "games" }
	end
	return { "games", "examples", "examples/overrides" }
end

Roots.GAME_PARENTS = Roots.parentsFor(Roots.LAYOUT)

local function isGame(fs: any, dir: string): boolean
	if dir == "." then
		return fs.isFile("default.project.json") and fs.isDir("src")
	end
	return fs.isFile(dir .. "/default.project.json") and fs.isDir(dir .. "/src")
end

-- The root game's name (deploy.json "name"), single-game mode.
function Roots.rootName(fs: any): string?
	if not fs.isFile("deploy.json") then
		return nil
	end
	return string.match(fs.readFile("deploy.json"), '"name"%s*:%s*"([^"]+)"')
end

-- `layout` (v1.5.0, optional, for specs): defaults to this run's Roots.LAYOUT
function Roots.gameDirs(fs: any, layout: string?): { string }
	local out = {}
	local parents = if layout then Roots.parentsFor(layout) else Roots.GAME_PARENTS
	if (layout or Roots.LAYOUT) == "single-game" then
		if isGame(fs, ".") then
			table.insert(out, ".")
		end
		return out
	end
	for _, parent in parents do
		if fs.isDir(parent) then
			for _, entry in fs.readDir(parent) do
				local dir = parent .. "/" .. entry
				if fs.isDir(dir) and isGame(fs, dir) then
					table.insert(out, dir)
				end
			end
		end
	end
	table.sort(out)
	return out
end

function Roots.findGame(fs: any, nameOrPath: string?, layout: string?): string?
	local parents = if layout then Roots.parentsFor(layout) else Roots.GAME_PARENTS
	if (layout or Roots.LAYOUT) == "single-game" then
		local wanted = clean(nameOrPath)
		if isGame(fs, ".") and (wanted == "." or wanted == Roots.rootName(fs)) then
			return "."
		end
		return nil
	end
	local trimmed = clean(nameOrPath)
	if string.find(trimmed, "/", 1, true) and fs.isDir(trimmed) and isGame(fs, trimmed) then
		return trimmed
	end
	for _, parent in parents do
		local dir = parent .. "/" .. trimmed
		if fs.isDir(dir) and isGame(fs, dir) then
			return dir
		end
	end
	return nil
end

return Roots
