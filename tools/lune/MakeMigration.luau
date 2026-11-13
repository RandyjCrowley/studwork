--!nocheck
--[[
	tools/lune/MakeMigration (StudWork v1.7.1): the parts of tools/make-migration that read a module
	the way the game does, and make its migrations/ folder reach the place. No requires: Lune's `fs`
	and `luau` are passed in. Specs: MakeMigration.spec.luau. The text generators stay in MakeGen.

	parseFrom(text) -> (n?, error?)
	    --from <n>: the module's CURRENT data.version, a positive integer
	evaluate(fs, luau, dir) -> (definition?, error?)
	    runs <dir>/module.luau under Lune with a stand-in Roblox: `script` / `script.Parent` /
	    :WaitForChild / :FindFirstChild walk the module's folder on disk (so
	    `require(script.Parent.shared.Save)` loads that file the same way), anything else (`game`,
	    the Framework, kit refs, Roblox globals) is an inert stub, and StudWork.defineModule returns
	    the table it is given. `require`, `getfenv`/`setfenv`, `loadstring` and `debug` are blocked,
	    but this is not a security sandbox: it runs the module's own code (as `tools/test` does), so
	    don't run make-migration on code you don't trust.
	resolveVersion(fs, luau, dir, source, from?) -> (result?, error?)
	    result = { version, how = "literal" | "evaluated" | "--from", expr, warning? }
	    A number literal is read as written; anything else (`Save.VERSION`, a local, a required
	    sibling) is evaluated. --from is for a version that can't be read: when the version resolves
	    and --from disagrees, it is an error (a gap in the migrations fails the boot). A version that
	    can't be resolved is an error that suggests --from.
	bumpReference(fs, luau, dir, source, expr, to) -> (edit?, error?)
	    where a non-literal data.version is defined, as one edit { path, text, line }: a local of
	    module.luau (`local VERSION = 2`), or a field of a module it requires from its own folder
	    (`version = Save.VERSION` with `local Save = require(script.Parent.shared.Save)` and one
	    `VERSION = 2` in that file, also through a local there). Only a single number literal is
	    rewritten; anything else is an error and the caller tells the user what to bump.
	projectFor(dir) -> (gameDir?, rel?)
	    a module at <gameDir>/modules/<folder> (or modules/<folder>: the project root, a
	    single-game project) -> (gameDir, "modules/<folder>")
	mapMigrations(SyncProjects, projectText, rel) -> (newText?, status)
	    status: "covered" (a $path maps the module folder or a parent of it: migrations/ is already
	    in the place), "present" (the module's node has `migrations`), "added" (newText maps
	    migrations next to every node whose `module` is <rel>/module.luau: ReplicatedStorage.
	    Modules.<Name> or the game module's ReplicatedStorage.GameModule), "unmapped" (no node
	    maps <rel>/module.luau: the caller fails and prints mappingSnippet)
	mappingSnippet(rel) -> string             the JSON to add next to the module's `module` entry
]]

local MakeMigration = {}

function MakeMigration.parseFrom(text: string?): (number?, string?)
	if text == nil or not string.match(text, "^%d+$") then
		return nil,
			"--from needs a positive integer (the module's current data.version), got " .. tostring(text)
	end
	local n = tonumber(text) :: number
	if n < 1 then
		return nil, "--from needs a positive integer (the module's current data.version), got " .. text
	end
	if n > 998 then
		return nil, "--from must be at most 998 (migration files are numbered 001..999), got " .. text
	end
	return n, nil
end

-- stand-in Roblox ------------------------------------------------------------------------------

local function dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or "."
end

local function basename(path: string): string
	return string.match(path, "([^/]+)$") or path
end

local STUB_MT = {}
local function stub(name: string?): any
	return setmetatable({ __stubName = name or "?" }, STUB_MT)
end
local captured: any = nil
STUB_MT.__index = function(_self, key)
	return stub(tostring(key))
end
STUB_MT.__newindex = function() end
STUB_MT.__call = function(self, ...)
	if rawget(self, "__stubName") == "defineModule" then
		local args = table.pack(...)
		for i = 1, args.n do
			local a = args[i]
			if type(a) == "table" and getmetatable(a) == nil then
				captured = a
				return a
			end
		end
	end
	return stub("result")
end
for _, op in { "__add", "__sub", "__mul", "__div", "__idiv", "__mod", "__pow", "__unm", "__concat" } do
	STUB_MT[op] = function()
		return stub(op)
	end
end
STUB_MT.__lt = function()
	return false
end
STUB_MT.__le = function()
	return false
end
STUB_MT.__len = function()
	return 0
end
STUB_MT.__iter = function()
	return next, {}
end
STUB_MT.__tostring = function(self)
	return "<stub " .. tostring(rawget(self, "__stubName")) .. ">"
end

-- The module's folder, read up front: the stand-ins below run inside metamethods, where Lune's
-- file calls can't yield (a spec runs in a coroutine).
local function snapshot(fs: any, root: string): any
	local snap = { dirs = {}, files = {} }
	local function walk(dir: string, depth: number)
		snap.dirs[dir] = true
		if depth > 8 then
			return
		end
		for _, entry in fs.readDir(dir) do
			local path = dir .. "/" .. entry
			if fs.isDir(path) then
				walk(path, depth + 1)
			elseif string.match(entry, "%.luau?$") then
				snap.files[path] = fs.readFile(path)
			end
		end
	end
	walk(root, 0)
	return {
		isDir = function(p: string): boolean
			return snap.dirs[p] == true
		end,
		isFile = function(p: string): boolean
			return snap.files[p] ~= nil
		end,
		readFile = function(p: string): string
			return assert(snap.files[p], "not in the module folder: " .. p)
		end,
	}
end

-- A node: a file (`<x>.luau`, or a folder with init.luau) or a folder of the module on disk.
local NODE_MT = {}
local function node(fs: any, path: string, file: string?): any
	return setmetatable({ __fs = fs, __path = path, __file = file }, NODE_MT)
end

local function child(self: any, name: string): any?
	local fs, path = rawget(self, "__fs"), rawget(self, "__path")
	if not fs.isDir(path) then
		return nil
	end
	local base = path .. "/" .. name
	for _, candidate in { base .. ".luau", base .. ".lua" } do
		if fs.isFile(candidate) then
			return node(fs, base, candidate)
		end
	end
	if fs.isDir(base) then
		for _, init in { base .. "/init.luau", base .. "/init.lua" } do
			if fs.isFile(init) then
				return node(fs, base, init)
			end
		end
		return node(fs, base, nil)
	end
	return nil
end

local NODE_METHODS = {
	WaitForChild = function(self, name)
		return child(self, name) or stub(name)
	end,
	FindFirstChild = function(self, name)
		return child(self, name)
	end,
	GetChildren = function()
		return {}
	end,
	IsA = function()
		return false
	end,
	GetFullName = function(self)
		return rawget(self, "__path")
	end,
}
NODE_MT.__index = function(self, key)
	if key == "Name" then
		return basename(rawget(self, "__path"))
	elseif key == "Parent" then
		local path = rawget(self, "__path")
		return node(rawget(self, "__fs"), dirname(path), nil)
	elseif key == "ClassName" then
		return if rawget(self, "__file") then "ModuleScript" else "Folder"
	elseif NODE_METHODS[key] then
		return NODE_METHODS[key]
	end
	return child(self, key) or stub(key)
end
NODE_MT.__tostring = function(self)
	return basename(rawget(self, "__path"))
end

-- The globals the evaluated code sees: the stand-ins first, then Lune's built-in libraries
-- (math, string, table, ...), then a stub for any other name (Roblox globals: Enum, Vector3, ...).
local GLOBALS = getfenv(1)
local BLOCKED = { require = true, getfenv = true, setfenv = true, _G = true, loadstring = true, debug = true }

local function loader(fs: any, luau: any)
	local cache: { [string]: any } = {}
	local loading: { [string]: boolean } = {}
	local load
	local function env(scriptNode: any): any
		local overrides = {
			script = scriptNode,
			game = stub("game"),
			workspace = stub("workspace"),
			shared = {},
			require = function(target: any): any
				if
					type(target) == "table"
					and getmetatable(target) == NODE_MT
					and rawget(target, "__file")
				then
					return load(target)
				end
				return stub("required")
			end,
		}
		return setmetatable(overrides, {
			__index = function(_, key)
				if not BLOCKED[key] then
					local v = GLOBALS[key]
					if v ~= nil then
						return v
					end
				end
				return stub(key)
			end,
		})
	end
	function load(target: any): any
		local file = rawget(target, "__file")
		if cache[file] ~= nil then
			return cache[file]
		end
		if loading[file] then
			return stub("cycle")
		end
		loading[file] = true
		local fn = luau.load(fs.readFile(file), {
			debugName = file,
			environment = env(target),
			injectGlobals = false,
		})
		local result = fn()
		loading[file] = nil
		cache[file] = if result == nil then stub("nil") else result
		return cache[file]
	end
	return load, env
end

function MakeMigration.evaluate(fs: any, luau: any, dir: string): (any?, string?)
	local file = dir .. "/module.luau"
	if not fs.isFile(file) then
		return nil, "no module.luau in " .. dir
	end
	local snap = snapshot(fs, dir)
	local load = loader(snap, luau)
	captured = nil
	local ok, result = pcall(load, node(snap, dir .. "/module", file))
	local def = captured
	captured = nil
	if not ok then
		return nil, tostring(result)
	end
	-- module.luau returns its definition; a defineModule call is the fallback
	if type(result) == "table" and getmetatable(result) == nil and rawget(result, "data") ~= nil then
		def = result
	end
	if def == nil then
		return nil, "module.luau did not call StudWork.defineModule({ ... })"
	end
	return def, nil
end

local function versionOf(def: any): (number?, string?)
	local data = def.data
	if type(data) ~= "table" or getmetatable(data) ~= nil then
		return nil, "no data = { ... } table"
	end
	local v = rawget(data, "version")
	if type(v) ~= "number" or v ~= math.floor(v) or v < 0 then
		return nil,
			"data.version is not a whole number (" .. (if type(v) == "table"
				then "unresolved"
				else tostring(v)) .. ")"
	end
	return v, nil
end

function MakeMigration.resolveVersion(
	fs: any,
	luau: any,
	dir: string,
	source: string,
	from: number?,
	MakeGen: any
): (any?, string?)
	local expr = MakeGen.versionExpr(source) or "?"
	local resolved, how, why = MakeGen.dataVersion(source), "literal", nil
	if resolved == nil then
		local def, err = MakeMigration.evaluate(fs, luau, dir)
		if def then
			resolved, why = versionOf(def)
		else
			why = err
		end
		how = "evaluated"
	end
	if from then
		if resolved ~= nil and resolved ~= from then
			return nil,
				string.format(
					"--from %d disagrees with data.version %d (`%s` in %s/module.luau): nothing was written."
						.. " --from is for a version that can't be read; a migration from %d would leave a gap"
						.. " that fails the boot",
					from,
					resolved,
					expr,
					dir,
					from
				)
		end
		return { version = from, how = "--from", expr = expr }, nil
	end
	if resolved == nil then
		return nil,
			string.format(
				"couldn't resolve data.version (`%s`) in %s/module.luau: %s; pass --from <n> with its current value",
				expr,
				dir,
				tostring(why)
			)
	end
	return { version = resolved, how = how, expr = expr }, nil
end

-- bumping a non-literal data.version ------------------------------------------------------------

local function escape(s: string): string
	return (string.gsub(s, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- every place `name` gets a number literal in `text`: `local name = 3`, `local name: number = 3`,
-- `name = 3` (a table field or an assignment, also `X.name = 3`)
local function literalSites(text: string, name: string): { { number } }
	local sites = {}
	local n = escape(name)
	-- the name matches exactly (`VERSION_FIRST` is not `VERSION`) and the literal is the whole
	-- right-hand side (`VERSION = 1 + X` is not a site): checked on the rest of the line
	local patterns = {
		"\n[ \t]*local[ \t]+" .. n .. "[ \t]*=[ \t]*()%d+()",
		"\n[ \t]*local[ \t]+" .. n .. "[ \t]*:[ \t]*[%a_][%w_%.]*[ \t]*=[ \t]*()%d+()",
		"\n[ \t]*" .. n .. "[ \t]*=[ \t]*()%d+()",
		"\n[ \t]*[%a_][%w_%.]*%." .. n .. "[ \t]*=[ \t]*()%d+()",
	}
	local padded = "\n" .. text
	local function wholeValue(e: number): boolean
		local rest = string.match(padded, "^[^\n]*", e) or ""
		rest = string.gsub(rest, "%-%-.*$", "")
		return string.match(rest, "^[ \t]*[,;]?[ \t]*$") ~= nil
	end
	local seen = {}
	for _, p in patterns do
		for s, e in string.gmatch(padded, p) do
			-- positions are in "\n" .. text
			if not seen[s] and wholeValue(e) then
				seen[s] = true
				table.insert(sites, { s - 1, e - 1 })
			end
		end
	end
	return sites
end

-- `name = IDENT` (a field set from a local of the same file)
local function aliasOf(text: string, name: string): string?
	local n = escape(name)
	local found = nil
	for _, p in
		{
			"\n[ \t]*" .. n .. "[ \t]*=[ \t]*([%a_][%w_]*)[ \t]*,?[ \t]*\n",
			"\n[ \t]*[%a_][%w_%.]*%." .. n .. "[ \t]*=[ \t]*([%a_][%w_]*)[ \t]*\n",
		}
	do
		for ident in string.gmatch("\n" .. text .. "\n", p) do
			if found and found ~= ident then
				return nil
			end
			found = ident
		end
	end
	return found
end

local function rewriteSite(text: string, name: string, to: number): (string?, string?)
	local sites = literalSites(text, name)
	if #sites == 0 then
		local alias = aliasOf(text, name)
		if alias and alias ~= name then
			sites = literalSites(text, alias)
			name = alias
		end
	end
	if #sites ~= 1 then
		return nil,
			if #sites == 0
				then "no `" .. name .. " = <number>` there"
				else "`" .. name .. "` is set to a number in " .. #sites .. " places"
	end
	local s, e = sites[1][1], sites[1][2]
	return string.sub(text, 1, s - 1) .. tostring(to) .. string.sub(text, e), nil
end

function MakeMigration.bumpReference(
	fs: any,
	luau: any,
	dir: string,
	source: string,
	expr: string,
	to: number
): (any?, string?)
	local modulePath = dir .. "/module.luau"
	local ident = string.match(expr, "^([%a_][%w_]*)$")
	if ident then
		local text, err = rewriteSite(source, ident, to)
		if text == nil then
			return nil, modulePath .. ": " .. tostring(err)
		end
		return { path = modulePath, text = text }, nil
	end
	local var, field = string.match(expr, "^([%a_][%w_]*)%.([%a_][%w_]*)$")
	if var == nil then
		return nil, "`" .. expr .. "` is neither a local nor <module>.<FIELD>"
	end
	local arg = string.match("\n" .. source, "\nlocal[ \t]+" .. escape(var) .. "[ \t]*=[ \t]*require(%b())")
	if arg == nil then
		return nil, "no `local " .. var .. " = require(...)` in " .. modulePath
	end
	local snap = snapshot(fs, dir)
	local _, env = loader(snap, luau)
	local ok, target = pcall(function()
		return luau.load("return " .. string.sub(arg, 2, -2), {
			debugName = modulePath,
			environment = env(node(snap, dir .. "/module", modulePath)),
			injectGlobals = false,
		})()
	end)
	local file = ok
		and type(target) == "table"
		and getmetatable(target) == NODE_MT
		and rawget(target, "__file")
	if not file then
		return nil, "`" .. var .. "` isn't required from a file in " .. dir
	end
	local text, err = rewriteSite(fs.readFile(file), field, to)
	if text == nil then
		return nil, file .. ": " .. tostring(err)
	end
	return { path = file, text = text }, nil
end

-- the Rojo project ------------------------------------------------------------------------------

function MakeMigration.projectFor(dir: string): (string?, string?)
	local clean = string.gsub(string.gsub(dir, "/+$", ""), "^%./", "")
	local folder = string.match(clean, "^modules/([^/]+)$")
	if folder then
		return ".", "modules/" .. folder
	end
	local gameDir, f = string.match(clean, "^(.+)/modules/([^/]+)$")
	if gameDir then
		return gameDir, "modules/" .. f
	end
	return nil, nil
end

local function normalize(p: string): string
	p = string.gsub(p, "^%./", "")
	p = string.gsub(p, "/+$", "")
	return p
end

function MakeMigration.mappingSnippet(rel: string): string
	return '"migrations": { "$path": "' .. rel .. '/migrations" }'
end

function MakeMigration.mapMigrations(SyncProjects: any, text: string, rel: string): (string?, string)
	local project = SyncProjects.decode(text)
	local tree = project.vals and project.vals.tree
	if type(tree) ~= "table" or not tree.__object then
		return nil, "unmapped"
	end
	local modulePath = rel .. "/module.luau"
	local covered, present = false, false
	local targets = {}
	local function walk(n: any)
		if type(n) ~= "table" or not n.__object then
			return
		end
		local p = n.vals["$path"]
		if type(p) == "string" then
			local np = normalize(p)
			if np == rel or (np ~= "" and string.sub(rel, 1, #np + 1) == np .. "/") then
				covered = true
			end
		end
		local m = n.vals.module
		if type(m) == "table" and m.__object and type(m.vals["$path"]) == "string" then
			if normalize(m.vals["$path"]) == modulePath then
				if n.vals.migrations ~= nil then
					present = true
				else
					table.insert(targets, n)
				end
			end
		end
		for _, key in n.keys do
			if string.sub(key, 1, 1) ~= "$" then
				walk(n.vals[key])
			end
		end
	end
	walk(tree)
	if covered then
		return nil, "covered"
	end
	if #targets == 0 then
		return nil, if present then "present" else "unmapped"
	end
	for _, n in targets do
		local entry = SyncProjects.newObject()
		SyncProjects.set(entry, "$path", rel .. "/migrations")
		SyncProjects.set(n, "migrations", entry)
	end
	return SyncProjects.encode(project), "added"
end

return MakeMigration
