--!nocheck
--[[
	Loads REAL core source files (and the vendored ProfileStore) into one simulated server with
	its own globals: fake `game`, `task`, `os`, `typeof`, `Instance`, `Enum`, `warn`. Every
	server gets its own module cache, so module-level state (ProfileStore's session list, Data's
	entries, Economy's states) is per server exactly as on Roblox.

	Spec files can't require @lune/* through the harness's `require`, but the Lune global table
	is reachable as the __index of the spec environment's metatable (luau.load injectGlobals),
	so this module takes the real Lune `require` from there. Sources are read ONCE when this
	module loads (main thread): Lune's fs yields, which would break the simulated coroutines if
	it happened inside one.
]]

local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local fs = luneRequire("@lune/fs")
local luau = luneRequire("@lune/luau")

local Loader = {}

local ROOTS = {
	"packages/core/shared",
	"packages/core/server",
	"packages/kits/collection/server",
	"packages/kits/economy/server",
	"packages/kits/base/server",
	"packages/kits/social/server",
	"packages/kits/engagement/server",
	"deps/ServerPackages",
}

local kinds: { [string]: "file" | "dir" } = {}
local listing: { [string]: { string } } = {}
local sources: { [string]: string } = {}

local function indexTree(dir: string)
	if not fs.isDir(dir) then
		return
	end
	kinds[dir] = "dir"
	local entries = fs.readDir(dir)
	table.sort(entries)
	listing[dir] = entries
	for _, entry in entries do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			if entry ~= "docs" then
				indexTree(path)
			end
		elseif string.match(entry, "%.luau?$") and not string.match(entry, "%.spec%.luau$") then
			kinds[path] = "file"
			sources[path] = fs.readFile(path)
		end
	end
end

for _, root in ROOTS do
	indexTree(root)
end

-- Rojo maps a wally package folder to its main file (default.project.json $path).
local ALIASES = {
	["deps/ServerPackages/ProfileStore"] = "deps/ServerPackages/_Index/lm-loleris_profilestore@1.0.3/profilestore/ProfileStore.luau",
}

local function basename(path: string): string
	return string.match(path, "([^/]+)$") or path
end

local function dirname(path: string): string
	return string.match(path, "^(.*)/[^/]+$") or "."
end

local function resolveChild(dir: string, name: string): string?
	if kinds[dir] ~= "dir" then
		return nil
	end
	local alias = ALIASES[dir .. "/" .. name]
	if alias then
		return alias
	end
	for _, candidate in { dir .. "/" .. name .. ".luau", dir .. "/" .. name .. ".lua", dir .. "/" .. name } do
		if kinds[candidate] then
			return candidate
		end
	end
	return nil
end

local nodeCache: { [string]: any } = {}

local function makeNode(path: string)
	if nodeCache[path] then
		return nodeCache[path]
	end
	local name = string.gsub(basename(path), "%.luau?$", "")
	local node = {}
	setmetatable(node, {
		__index = function(_, key)
			if key == "Name" then
				return name
			elseif key == "__path" then
				return path
			elseif key == "Parent" then
				return makeNode(dirname(path))
			elseif key == "FindFirstChild" or key == "WaitForChild" then
				return function(_self, childName)
					local child = resolveChild(path, childName)
					if child then
						return makeNode(child)
					end
					if key == "WaitForChild" then
						error(
							"sim: WaitForChild('" .. tostring(childName) .. "') not found under " .. path,
							2
						)
					end
					return nil
				end
			elseif key == "IsA" then
				return function(_self, className)
					return className == "ModuleScript" or className == "Instance"
				end
			elseif key == "GetChildren" then
				return function()
					local list = {}
					for _, entry in listing[path] or {} do
						if entry ~= "init.luau" and not string.match(entry, "%.spec%.luau$") then
							table.insert(list, makeNode(path .. "/" .. entry))
						end
					end
					return list
				end
			end
			local child = resolveChild(path, key)
			if child then
				return makeNode(child)
			end
			error("sim: '" .. tostring(key) .. "' is not a valid member of " .. path, 2)
		end,
		__tostring = function()
			return "SimNode(" .. path .. ")"
		end,
	})
	nodeCache[path] = node
	return node
end

Loader.node = makeNode

-- A folder whose children are named nodes (ReplicatedStorage.Core, ServerStorage.ServerPackages).
function Loader.folder(children: { [string]: any })
	local function find(_, childName)
		local child = children[childName]
		if type(child) == "string" then
			return makeNode(child)
		end
		return child
	end
	return setmetatable({}, {
		__index = function(_, key)
			if key == "FindFirstChild" then
				return find
			elseif key == "WaitForChild" then
				return function(self, childName)
					local found = find(self, childName)
					if found == nil then
						error("sim: folder has no child " .. tostring(childName), 2)
					end
					return found
				end
			end
			local found = find(nil, key)
			if found == nil then
				error("sim: folder has no member " .. tostring(key), 2)
			end
			return found
		end,
	})
end

local function fileOf(path: string): string
	if kinds[path] == "dir" then
		local init = path .. "/init.luau"
		assert(kinds[init] == "file", "sim: folder " .. path .. " is not a module (no init.luau)")
		return init
	end
	assert(kinds[path] == "file", "sim: no such module " .. path)
	return path
end

-- Returns a require() bound to `globals` with its own module cache.
function Loader.newRequire(globals: { [string]: any })
	local cache: { [string]: any } = {}
	local loading: { [string]: boolean } = {}
	local requireFn
	requireFn = function(target: any)
		if type(target) == "string" then
			target = makeNode(target)
		end
		local file = fileOf(target.__path)
		local cached = cache[file]
		if cached ~= nil then
			return cached.value
		end
		assert(not loading[file], "sim: cyclic require of " .. file)
		loading[file] = true
		local env = table.clone(globals)
		env.script = target
		env.require = requireFn
		local chunk = luau.load(sources[file], { debugName = file, environment = env })
		local value = chunk()
		loading[file] = nil
		cache[file] = { value = value }
		return value
	end
	return requireFn
end

return Loader
