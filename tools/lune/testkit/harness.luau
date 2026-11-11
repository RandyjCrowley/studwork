--!nocheck
--[[
	Core test harness for Lune (pure-logic tests).

	Why not Jest-Lua: it needs a real Roblox engine (run-in-roblox is unmaintained since 2020), so
	pure logic is tested here under Lune with a tiny Jest-style API. See docs/decisions.md.

	How modules load: every file is loaded with a fake `script` Instance that maps onto the
	filesystem, so production code keeps Roblox-style requires (`require(script.Parent.Types)`)
	and still runs here. Folders map to folders; `X.luau` and `X/init.luau` map to ModuleScripts.
	Only pure modules can be tested this way: anything touching `game`, Instances or services at
	load time needs injected fakes (pass them as function parameters - see CLAUDE.md).

	Spec files (`*.spec.luau`) get these globals: describe, it, expect, beforeEach, afterEach,
	Stubs (minimal Color3/Vector3/UDim2 stand-ins). Rojo ignores *.spec.luau (globIgnorePaths).
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Harness = {}

--------------------------------------------------------------------------------
-- Minimal Roblox value stubs (enough for pure modules that format colours etc.)
--------------------------------------------------------------------------------

local Stubs = {}

Stubs.Color3 = {
	fromHex = function(hex: string)
		assert(type(hex) == "string" and string.match(hex, "^#?%x%x%x%x%x%x$"), "bad hex " .. tostring(hex))
		local h = string.gsub(hex, "#", "")
		return {
			R = tonumber(string.sub(h, 1, 2), 16) / 255,
			G = tonumber(string.sub(h, 3, 4), 16) / 255,
			B = tonumber(string.sub(h, 5, 6), 16) / 255,
			__stub = "Color3",
		}
	end,
	fromRGB = function(r, g, b)
		return { R = r / 255, G = g / 255, B = b / 255, __stub = "Color3" }
	end,
	new = function(r, g, b)
		return { R = r or 0, G = g or 0, B = b or 0, __stub = "Color3" }
	end,
}

Stubs.Vector3 = {
	new = function(x, y, z)
		return { X = x or 0, Y = y or 0, Z = z or 0, __stub = "Vector3" }
	end,
}

Stubs.UDim2 = {
	new = function(xs, xo, ys, yo)
		return { X = { Scale = xs, Offset = xo }, Y = { Scale = ys, Offset = yo }, __stub = "UDim2" }
	end,
	fromScale = function(x, y)
		return { X = { Scale = x, Offset = 0 }, Y = { Scale = y, Offset = 0 }, __stub = "UDim2" }
	end,
}

Harness.Stubs = Stubs

--------------------------------------------------------------------------------
-- Fake script tree + loader
--------------------------------------------------------------------------------

-- Lune's fs calls yield, and metamethods (__index) cannot yield, so the tree is indexed once up
-- front and every lookup inside the fake Instances reads this index instead of the filesystem.
local index: { [string]: "file" | "dir" } = {}
local listing: { [string]: { string } } = {}

local INDEX_ROOTS = { "packages", "games", "templates", "examples", "deps/Packages", "deps/ServerPackages" }
local SKIP = { [".git"] = true, node_modules = true }

local function indexTree(dir: string)
	if not fs.isDir(dir) then
		return
	end
	index[dir] = "dir"
	local entries = fs.readDir(dir)
	table.sort(entries)
	listing[dir] = entries
	for _, entry in entries do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			if not SKIP[entry] then
				indexTree(path)
			end
		else
			index[path] = "file"
		end
	end
end

for _, root in INDEX_ROOTS do
	indexTree(root)
end

local function isFile(path: string): boolean
	return index[path] == "file"
end

local function isDir(path: string): boolean
	return index[path] == "dir"
end

local moduleCache: { [string]: any } = {}
local loading: { [string]: boolean } = {}

local function normalize(path: string): string
	local parts = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return table.concat(parts, "/")
end

local function dirname(path: string): string
	local d = string.match(path, "^(.*)/[^/]+$")
	return d or "."
end

local function basename(path: string): string
	return string.match(path, "([^/]+)$") or path
end

local makeNode

-- Resolve the child `name` of directory/module node `nodePath`.
local function resolveChild(nodePath: string, isDirLike: boolean, name: string): string?
	-- A ModuleScript file `X.luau` has no children; `X/init.luau` has its folder's children.
	local dir = nodePath
	if not isDirLike then
		return nil
	end
	local candidates = {
		dir .. "/" .. name .. ".luau",
		dir .. "/" .. name .. ".lua",
		dir .. "/" .. name,
	}
	for _, candidate in candidates do
		if isFile(candidate) or isDir(candidate) then
			return candidate
		end
	end
	return nil
end

makeNode = function(path: string)
	-- path: a file (X.luau), a directory, or a directory with init.luau
	local isDir = isDir(path)
	local node = {}
	local name = string.gsub(basename(path), "%.luau?$", "")
	local meta = {}
	meta.__index = function(_, key)
		if key == "Name" then
			return name
		elseif key == "__path" then
			return path
		elseif key == "Parent" then
			local parentPath = dirname(path)
			-- a file inside a folder that has init.luau: its parent is the folder node (the module)
			return makeNode(parentPath)
		elseif key == "FindFirstChild" or key == "WaitForChild" then
			return function(_self, childName)
				local childPath = resolveChild(path, isDir, childName)
				if childPath then
					return makeNode(childPath)
				end
				if key == "WaitForChild" then
					error("harness: WaitForChild('" .. childName .. "') not found under " .. path, 2)
				end
				return nil
			end
		elseif key == "IsA" then
			return function(_, className)
				return className == "ModuleScript" or className == "Instance"
			end
		elseif key == "GetChildren" then
			return function()
				local list = {}
				if isDir then
					for _, entry in listing[path] or {} do
						if entry ~= "init.luau" and not string.match(entry, "%.spec%.luau$") then
							table.insert(list, makeNode(path .. "/" .. entry))
						end
					end
				end
				return list
			end
		end
		local childPath = resolveChild(path, isDir, key)
		if childPath then
			return makeNode(childPath)
		end
		error("harness: '" .. tostring(key) .. "' is not a valid member of " .. path, 2)
	end
	meta.__tostring = function()
		return "Node(" .. path .. ")"
	end
	return setmetatable(node, meta)
end

-- Fake `game` exposing only the Rojo mapping of core (see games/_sandbox/default.project.json):
--   ReplicatedStorage.FrameworkClient -> packages/framework/client, .UI -> packages/ui,
--   .Packages -> Packages, .Framework -> packages/framework/shared,
--   .Modules.<Name>.{module,client,shared} -> each module folder's parts (below);
--   ServerScriptService.Framework -> packages/framework/server, .FrameworkTest ->
--   packages/framework/test (StudWork.test), .Modules.<Name> -> each module's server/.
-- Any other service errors, so a spec cannot silently depend on the engine.
local folderNode
function folderNode(children: { [string]: any })
	local node = {}
	local function find(_, name)
		local path = children[name]
		if type(path) == "table" then
			return folderNode(path)
		end
		if path and (isDir(path) or isFile(path)) then
			return makeNode(path)
		end
		return nil
	end
	return setmetatable(node, {
		__index = function(_, key)
			if key == "FindFirstChild" then
				return find
			elseif key == "WaitForChild" then
				return function(self, name)
					local found = find(self, name)
					if not found then
						error("harness: fake service has no child " .. tostring(name), 2)
					end
					return found
				end
			end
			local found = find(nil, key)
			if found then
				return found
			end
			error("harness: fake service has no member " .. tostring(key), 2)
		end,
	})
end

-- Every shipped module folder (packages/kits/*/*/module.luau, examples/modules/*/module.luau),
-- mapped like Rojo (core-v1.3.1 R19, module-api.md §1): ReplicatedStorage.Modules.<Name>.{module,
-- client, shared} and ServerScriptService.Modules.<Name> (the server part). Discovery is shared
-- with the sim and tools/sync-projects (tools/lune/ModuleDiscovery.luau).
local ModuleDiscovery = require("../ModuleDiscovery")
local MODULE_CHILDREN = ModuleDiscovery.children(ModuleDiscovery.discover(fs))

local BASE_CHILDREN: { [string]: { [string]: any } } = {
	ReplicatedStorage = {
		FrameworkClient = "packages/framework/client",
		UI = "packages/ui",
		Packages = "deps/Packages",
		Framework = "packages/framework/shared",
		Modules = MODULE_CHILDREN.ReplicatedStorage,
	},
	ServerScriptService = {
		Framework = "packages/framework/server",
		FrameworkTest = "packages/framework/test", -- the StudWork module harness (specs only)
		Modules = MODULE_CHILDREN.ServerScriptService,
	},
}

local function servicesFrom(children: { [string]: { [string]: any } }): { [string]: any }
	local out = {}
	for name, kids in children do
		out[name] = folderNode(kids)
	end
	return out
end

local fakeServices = servicesFrom(BASE_CHILDREN)

-- A spec under games/<g>/ or templates/<t>/ (Phase 2, E R2): that game's Rojo project adds its own
-- ReplicatedStorage / ServerScriptService children (Game, GameModule, Modules, ...) next to the
-- framework/kit mapping above (names the mapping already has keep the mapping's path), so a
-- Config listing a game-local module (ReplicatedStorage.Modules.<X>.module) loads.
local function projectChildren(dir: string, node: any): { [string]: any }
	local out: { [string]: any } = {}
	for name, child in node do
		if string.sub(name, 1, 1) ~= "$" and type(child) == "table" then
			if type(child["$path"]) == "string" then
				out[name] = normalize(dir .. "/" .. child["$path"])
			else
				out[name] = projectChildren(dir, child)
			end
		end
	end
	return out
end

function Harness.mapGame(specPath: string?)
	local gameDir = if specPath
		then (string.match(specPath, "^(games/[^/]+)/") or string.match(specPath, "^(templates/[^/]+)/"))
		else nil
	local projectPath = if gameDir then gameDir .. "/default.project.json" else nil
	if projectPath == nil or not fs.isFile(projectPath) then
		fakeServices = servicesFrom(BASE_CHILDREN)
		return
	end
	local project = serde.decode("json", fs.readFile(projectPath))
	-- names the base mapping already has keep the base path; folders (Modules) merge per child,
	-- so the game's own ServerScriptService.Modules.<GameModule> sits next to the kit modules
	local function merge(base: { [string]: any }, extra: { [string]: any }): { [string]: any }
		local kids = table.clone(base)
		for name, value in extra do
			if kids[name] == nil then
				kids[name] = value
			elseif type(kids[name]) == "table" and type(value) == "table" then
				kids[name] = merge(kids[name], value)
			end
		end
		return kids
	end
	local merged: { [string]: { [string]: any } } = {}
	for serviceName, base in BASE_CHILDREN do
		local tree = project.tree and project.tree[serviceName]
		merged[serviceName] = if type(tree) == "table"
			then merge(base, projectChildren(gameDir :: string, tree))
			else table.clone(base)
	end
	fakeServices = servicesFrom(merged)
end

local fakeGame = setmetatable({}, {
	__index = function(_, key)
		if key == "GetService" then
			return function(_, name)
				local service = fakeServices[name]
				if service == nil then
					error(
						"harness: game:GetService('"
							.. tostring(name)
							.. "') is not available in Lune tests; inject it",
						2
					)
				end
				return service
			end
		end
		error("harness: game." .. tostring(key) .. " is not available in Lune tests", 2)
	end,
})

Harness.game = fakeGame

local baseGlobals = {
	game = fakeGame,
	print = print,
	warn = warn,
	error = error,
	assert = assert,
	type = type,
	typeof = typeof,
	tostring = tostring,
	tonumber = tonumber,
	pairs = pairs,
	ipairs = ipairs,
	next = next,
	select = select,
	pcall = pcall,
	xpcall = xpcall,
	setmetatable = setmetatable,
	getmetatable = getmetatable,
	rawget = rawget,
	rawset = rawset,
	rawequal = rawequal,
	rawlen = rawlen,
	unpack = table.unpack,
	table = table,
	string = string,
	math = math,
	os = os,
	coroutine = coroutine,
	buffer = buffer,
	bit32 = bit32,
	utf8 = utf8,
	task = task,
	newproxy = newproxy,
	Color3 = Stubs.Color3,
	Vector3 = Stubs.Vector3,
	UDim2 = Stubs.UDim2,
}

local requireNode

local function loadFile(filePath: string, node: any, extraGlobals: { [string]: any }?)
	local source = fs.readFile(filePath)
	-- Copy globals in directly: luau.load(injectGlobals) replaces the env metatable.
	local env = table.clone(baseGlobals)
	env.script = node
	env.require = requireNode
	if extraGlobals then
		for k, v in extraGlobals do
			env[k] = v
		end
	end
	local chunk = luau.load(source, { debugName = filePath, environment = env })
	return chunk()
end

requireNode = function(target: any)
	if type(target) == "string" then
		-- allow plain path requires from tests: require("packages/framework/shared/Types")
		target = makeNode(target)
	end
	local path = target.__path
	local filePath = path
	if isDir(path) then
		filePath = path .. "/init.luau"
		assert(isFile(filePath), "harness: folder " .. path .. " is not a module (no init.luau)")
	end
	filePath = normalize(filePath)
	if moduleCache[filePath] ~= nil then
		return moduleCache[filePath]
	end
	assert(not loading[filePath], "harness: cyclic require of " .. filePath)
	loading[filePath] = true
	local result = loadFile(filePath, target)
	loading[filePath] = nil
	moduleCache[filePath] = if result == nil then false else result
	return result
end

Harness.require = requireNode
Harness.makeNode = makeNode

function Harness.resetModuleCache()
	table.clear(moduleCache)
end

--------------------------------------------------------------------------------
-- Jest-style API
--------------------------------------------------------------------------------

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function fmt(v: any): string
	if type(v) == "string" then
		return string.format("%q", v)
	elseif type(v) == "table" then
		local parts = {}
		local n = 0
		for k, val in v do
			n += 1
			if n > 8 then
				table.insert(parts, "...")
				break
			end
			table.insert(parts, tostring(k) .. "=" .. fmt(val))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(v)
end

local function expect(actual: any)
	local matchers = {}
	local negate = false
	local function check(ok: boolean, message: string)
		if negate then
			ok = not ok
			message = "NOT " .. message
		end
		if not ok then
			error(message, 3)
		end
	end
	function matchers.toBe(expected)
		check(actual == expected, "expected " .. fmt(actual) .. " to be " .. fmt(expected))
	end
	function matchers.toEqual(expected)
		check(deepEqual(actual, expected), "expected " .. fmt(actual) .. " to equal " .. fmt(expected))
	end
	function matchers.toBeNear(expected, epsilon)
		epsilon = epsilon or 1e-6
		check(
			type(actual) == "number" and math.abs(actual - expected) <= epsilon,
			"expected " .. fmt(actual) .. " to be within " .. epsilon .. " of " .. fmt(expected)
		)
	end
	function matchers.toBeTruthy()
		check(not not actual, "expected " .. fmt(actual) .. " to be truthy")
	end
	function matchers.toBeFalsy()
		check(not actual, "expected " .. fmt(actual) .. " to be falsy")
	end
	function matchers.toBeNil()
		check(actual == nil, "expected " .. fmt(actual) .. " to be nil")
	end
	function matchers.toBeGreaterThan(n)
		check(type(actual) == "number" and actual > n, "expected " .. fmt(actual) .. " > " .. fmt(n))
	end
	function matchers.toBeGreaterThanOrEqual(n)
		check(type(actual) == "number" and actual >= n, "expected " .. fmt(actual) .. " >= " .. fmt(n))
	end
	function matchers.toBeLessThan(n)
		check(type(actual) == "number" and actual < n, "expected " .. fmt(actual) .. " < " .. fmt(n))
	end
	function matchers.toBeLessThanOrEqual(n)
		check(type(actual) == "number" and actual <= n, "expected " .. fmt(actual) .. " <= " .. fmt(n))
	end
	function matchers.toContain(item)
		local found = false
		if type(actual) == "string" then
			found = string.find(actual, item, 1, true) ~= nil
		elseif type(actual) == "table" then
			for _, v in actual do
				if v == item then
					found = true
					break
				end
			end
		end
		check(found, "expected " .. fmt(actual) .. " to contain " .. fmt(item))
	end
	function matchers.toThrow(substring)
		local ok, err = pcall(actual)
		local matched = not ok and (substring == nil or string.find(tostring(err), substring, 1, true) ~= nil)
		check(
			matched,
			"expected function to throw"
				.. (substring and (" '" .. substring .. "'") or "")
				.. ", got "
				.. tostring(err)
		)
	end
	local proxy = setmetatable({}, {
		__index = function(_, key)
			if key == "never" or key == "Not" then
				negate = not negate
				return matchers
			end
			return matchers[key]
		end,
	})
	return proxy
end

-- Runs one spec file; returns passed, failed, failure messages.
function Harness.runSpec(specPath: string): (number, number, { string })
	local tests: { { name: string, fn: () -> () } } = {}
	local prefix: { string } = {}
	local befores: { () -> () } = {}
	local afters: { () -> () } = {}

	local globals = {
		describe = function(name: string, fn: () -> ())
			table.insert(prefix, name)
			fn()
			table.remove(prefix)
		end,
		it = function(name: string, fn: () -> ())
			local full = table.concat(prefix, " > ")
			table.insert(tests, { name = (full ~= "" and (full .. " > ") or "") .. name, fn = fn })
		end,
		expect = expect,
		beforeEach = function(fn)
			table.insert(befores, fn)
		end,
		afterEach = function(fn)
			table.insert(afters, fn)
		end,
		Stubs = Stubs,
	}

	Harness.resetModuleCache()
	Harness.mapGame(specPath)
	local ok, err = pcall(loadFile, specPath, makeNode(specPath), globals)
	if not ok then
		return 0, 1, { specPath .. " (load): " .. tostring(err) }
	end

	local passed, failed = 0, 0
	local failures = {}
	for _, test in tests do
		for _, b in befores do
			b()
		end
		local tok, terr = pcall(test.fn)
		for _, a in afters do
			a()
		end
		if tok then
			passed += 1
		else
			failed += 1
			table.insert(failures, specPath .. " :: " .. test.name .. "\n      " .. tostring(terr))
		end
	end
	return passed, failed, failures
end

return Harness
