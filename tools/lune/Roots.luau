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

function Roots.core(path: string): string
	return Roots.prefix(Roots.CORE, path)
end

Roots.GAME_PARENTS = if Roots.external then { "games" } else { "games", "examples", "examples/overrides" }

local function isGame(fs: any, dir: string): boolean
	return fs.isFile(dir .. "/default.project.json") and fs.isDir(dir .. "/src")
end

function Roots.gameDirs(fs: any): { string }
	local out = {}
	for _, parent in Roots.GAME_PARENTS do
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

function Roots.findGame(fs: any, nameOrPath: string): string?
	local trimmed = clean(nameOrPath)
	if string.find(trimmed, "/", 1, true) and fs.isDir(trimmed) and isGame(fs, trimmed) then
		return trimmed
	end
	for _, parent in Roots.GAME_PARENTS do
		local dir = parent .. "/" .. trimmed
		if fs.isDir(dir) and isGame(fs, dir) then
			return dir
		end
	end
	return nil
end

return Roots
