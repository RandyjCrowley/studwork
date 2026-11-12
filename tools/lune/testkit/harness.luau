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
local process = require("@lune/process")
local task = require("@lune/task")
local PathUtil = require("./pathutil")

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

-- Core folders are reached through Roots.core (StudWork v1.4.0: in a games repo the core is the
-- `roblox-core/` submodule and the working directory is the games repo); the project's own game
-- folders (games/, and in the core repo templates/ + examples/) are indexed as they are.
local Roots = require("../Roots")
local INDEX_ROOTS = {}
for _, root in
	{
		Roots.core("packages"),
		Roots.core("templates"),
		Roots.core("examples"),
		Roots.core("deps/Packages"),
		Roots.core("deps/ServerPackages"),
		"games",
		"templates",
		"examples",
	}
do
	if not table.find(INDEX_ROOTS, root) then
		table.insert(INDEX_ROOTS, root)
	end
end
-- (v1.5.0) a single-game project: the game is the project root (its own folders, never the
-- studwork/ submodule beyond the core folders above)
if Roots.single then
	for _, root in { "src", "modules" } do
		table.insert(INDEX_ROOTS, root)
	end
end
local SKIP = { [".git"] = true, node_modules = true }

-- dir -> the events its net.blink declares (read once, here: file reads yield, metamethods can't)
local blinkEvents: { [string]: { { name: string, from: string? } } } = {}

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
			if entry == "net.blink" then
				local events = {}
				for name, body in string.gmatch(fs.readFile(path), "event%s+([%w_]+)%s*(%b{})") do
					table.insert(events, { name = name, from = string.match(body, "From:%s*(%w+)") })
				end
				blinkEvents[dir] = events
			end
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
		elseif key == "__blinkEvents" then
			-- (v1.7.0) the events of the net.blink next to this server part's folder (read when the
			-- tree was indexed: a metamethod can't read files): { { name, from = "Server" | "Client" } }
			return blinkEvents[dirname(path)] or {}
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

-- Fake `game` exposing only the Rojo mapping of core (see examples/sandbox/default.project.json;
-- every path below goes through Roots.core):
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
-- mapped like Rojo (v1.3.1 R19, module-api.md §1): ReplicatedStorage.Modules.<Name>.{module,
-- client, shared} and ServerScriptService.Modules.<Name> (the server part). Discovery is shared
-- with the sim and tools/sync-projects (tools/lune/ModuleDiscovery.luau).
local ModuleDiscovery = require("../ModuleDiscovery")
local MODULE_CHILDREN = ModuleDiscovery.children(ModuleDiscovery.discover(fs, Roots.CORE))

local BASE_CHILDREN: { [string]: { [string]: any } } = {
	ReplicatedStorage = {
		FrameworkClient = Roots.core("packages/framework/client"),
		UI = Roots.core("packages/ui"),
		Packages = Roots.core("deps/Packages"),
		Framework = Roots.core("packages/framework/shared"),
		Modules = MODULE_CHILDREN.ReplicatedStorage,
	},
	ServerScriptService = {
		Framework = Roots.core("packages/framework/server"),
		FrameworkTest = Roots.core("packages/framework/test"), -- the StudWork module harness (specs only)
		Modules = MODULE_CHILDREN.ServerScriptService,
	},
}

-- (StudWork v1.7.0) Workspace and Players in a spec. A game module's server part reads both at the
-- top of the file or in `start` (the scaffolded game module does), so they must exist under Lune:
--   Workspace  an EMPTY world: FindFirstChild / FindFirstChildOfClass / FindFirstChildWhichIsA
--              return nil, GetChildren / GetDescendants return {}; any other member errors (a
--              spec that needs a real part builds it itself and injects it through a seam).
--   Players    GetPlayers / GetPlayerByUserId see the players StudWork.test's harness added
--              (h:addPlayer / h:removePlayer keep the list); GetPlayerFromCharacter is nil;
--              PlayerAdded / PlayerRemoving accept Connect and never fire (use ctx.lifecycle).
local function signalStub(): any
	return {
		Connect = function(_self: any, _fn: any): any
			return { Disconnect = function() end, Connected = true }
		end,
	}
end

local function stubService(name: string, members: { [string]: any }): any
	return setmetatable({ Name = name, ClassName = name }, {
		__index = function(_, key)
			local member = members[key]
			if member ~= nil then
				return member
			end
			error("harness: " .. name .. "." .. tostring(key) .. " is not available in Lune tests", 2)
		end,
	})
end

local function workspaceStub(): any
	local function none()
		return nil
	end
	local function empty()
		return {}
	end
	return stubService("Workspace", {
		FindFirstChild = none,
		FindFirstChildOfClass = none,
		FindFirstChildWhichIsA = none,
		FindFirstAncestor = none,
		GetChildren = empty,
		GetDescendants = empty,
	})
end

local harnessPlayers: { any } = {}
-- (v1.7.0) userdata proxies a spec's mock Players registered as Instances: typeof() answers
-- "Instance" for them (as in Studio), type() stays "userdata". Weak keys: nothing keeps them alive.
local instanceProxies: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local function specTypeof(value: any): string
	if instanceProxies[value] then
		return "Instance"
	end
	return typeof(value)
end
local function playersStub(): any
	return stubService("Players", {
		GetPlayers = function(_self: any): { any }
			return table.clone(harnessPlayers)
		end,
		GetPlayerByUserId = function(_self: any, userId: number): any
			for _, p in harnessPlayers do
				if p.UserId == userId then
					return p
				end
			end
			return nil
		end,
		GetPlayerFromCharacter = function(): any
			return nil
		end,
		PlayerAdded = signalStub(),
		PlayerRemoving = signalStub(),
		__markInstance = function(proxy: any)
			instanceProxies[proxy] = true
		end,
		-- the framework harness (packages/framework/test/harness.luau) keeps the list current
		__setStudWorkPlayers = function(list: { any })
			harnessPlayers = list
		end,
	})
end

local guidCounter = 0
local function httpServiceStub(): any
	return stubService("HttpService", {
		GenerateGUID = function(_self: any, wrap: boolean?): string
			guidCounter += 1
			local guid = string.format("00000000-0000-4000-8000-%012d", guidCounter)
			return if wrap == false then guid else "{" .. guid .. "}"
		end,
		JSONEncode = function(_self: any, value: any): string
			return serde.encode("json", value)
		end,
		JSONDecode = function(_self: any, text: string): any
			return serde.decode("json", text)
		end,
	})
end

local workspaceService = workspaceStub()
local playersService = playersStub()
local httpService = httpServiceStub()

local function servicesFrom(children: { [string]: { [string]: any } }): { [string]: any }
	local out = {}
	for name, kids in children do
		out[name] = folderNode(kids)
	end
	out.Workspace = workspaceService
	out.Players = playersService
	out.HttpService = httpService
	return out
end

local fakeServices = servicesFrom(BASE_CHILDREN)

-- A spec inside a game folder (games/<g>/, examples/sandbox/, examples/overrides/<g>/,
-- templates/new-game/, an example module's tests/fixture-game/: the nearest folder above the spec
-- with a default.project.json; v1.3.0): that game's Rojo project adds its own
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

-- The game folder whose default.project.json maps a spec: the closest folder above the spec that
-- has one, else (v1.6.0) the project root "." when ./default.project.json exists (a single-game
-- project's root IS the game; the core repo and a games repo have no root project file, so nothing
-- changes there). `has(path)` tells whether a file exists. nil = no project file (base mapping).
function Harness.findGameDir(specPath: string?, has: (string) -> boolean): string?
	if specPath == nil then
		return nil
	end
	local dir = dirname(normalize(specPath))
	while dir ~= "." and dir ~= "" do
		if has(dir .. "/default.project.json") then
			return dir
		end
		local up = dirname(dir)
		if up == dir then
			break
		end
		dir = up
	end
	if string.sub(specPath, 1, 1) ~= "/" and has("default.project.json") then
		return "."
	end
	return nil
end

function Harness.mapGame(specPath: string?)
	local gameDir = Harness.findGameDir(specPath, function(path: string): boolean
		return isFile(path) or (path == "default.project.json" and fs.isFile(path))
	end)
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
	workspace = workspaceService,
	print = print,
	warn = warn,
	error = error,
	assert = assert,
	type = type,
	typeof = specTypeof,
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
		-- (core paths: in a games repo they resolve inside the core submodule, Roots.core)
		local plain = target
		if Roots.external and not isFile(plain) and not isDir(plain) then
			local inCore = Roots.core(plain)
			if isFile(inCore) or isDir(inCore) then
				plain = inCore
			end
		end
		target = makeNode(plain)
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

-- (v1.6.0 dogfood) Runs fn in its own thread and waits for it, so a test can never end the run
-- silently. Before this, test code ran on the runner's main thread under pcall: a raw
-- coroutine.yield (a sim task.wait called outside a server thread, e.g. a yielding
-- UserOwnsGamePassAsync reached from a spec) suspended the MAIN thread, nothing ever resumed it,
-- Lune's scheduler drained and the process exited 0 with no output at all. Now the main thread
-- keeps polling (Lune's own yields, fs/process/task.wait, still work in the test thread) and a
-- thread that hasn't finished after Harness.TIMEOUT wall seconds (env STUDWORK_TEST_TIMEOUT) is a
-- failure with its traceback. -> (ok, err) like pcall.
Harness.TIMEOUT = tonumber(process.env.STUDWORK_TEST_TIMEOUT) or 60

function Harness.guarded(fn: () -> (), timeout: number?): (boolean, any)
	local limit = timeout or Harness.TIMEOUT
	local finished, ok, err = false, false, nil
	local thread = task.spawn(function()
		ok, err = xpcall(fn, function(e)
			return e
		end)
		finished = true
	end)
	if finished then
		return ok, err
	end
	local start = os.clock()
	while not finished and os.clock() - start < limit do
		task.wait(0.01)
	end
	if finished then
		return ok, err
	end
	local where = debug.traceback(thread)
	pcall(coroutine.close, thread)
	return false,
		string.format(
			"the test never completed: its thread is still suspended after %g s (a yield that never resumes: a raw coroutine.yield, or a sim task.wait / yielding engine call on the spec's own thread instead of server:spawn / a transaction). Where it stopped:\n%s",
			limit,
			where
		)
end

-- Runs one spec file; returns passed, failed, failure messages.
function Harness.runSpec(specPath: string): (number, number, { string })
	-- The indexed tree uses project-relative paths. Explicit absolute paths inside the
	-- current project must use those same keys for both loading and Rojo mapping.
	if string.sub(specPath, 1, 1) == "/" then
		-- normalised on both sides: a cwd with or without a trailing "/" and doubled slashes in the
		-- spec path (CI: $TMPDIR unset, cwd "<repo>/") must still reduce to a project-relative key
		local cwd = string.gsub(process.exec("pwd", {}).stdout, "%s+$", "")
		specPath = PathUtil.relativeTo(specPath, cwd)
			or PathUtil.relativeTo(specPath, process.cwd)
			or specPath
	end
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
	local ok, err = Harness.guarded(function()
		loadFile(specPath, makeNode(specPath), globals)
	end)
	if not ok then
		return 0, 1, { specPath .. " (load): " .. tostring(err) }
	end

	local passed, failed = 0, 0
	local failures = {}
	for _, test in tests do
		for _, b in befores do
			b()
		end
		local tok, terr = Harness.guarded(test.fn)
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
