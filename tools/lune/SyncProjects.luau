--!nocheck
--[[
	tools/lune/SyncProjects: pure core of tools/sync-projects (v1.3.1, R19: one folder per
	module, module-api.md §1). Every *.project.json under games/, templates/ and examples/ maps
	each shipped module folder the same way:
	  module.luau -> ReplicatedStorage.Modules.<Name>.module
	  client/     -> ReplicatedStorage.Modules.<Name>.client   (when the folder exists)
	  shared/     -> ReplicatedStorage.Modules.<Name>.shared   (when the folder exists)
	  server/     -> ServerScriptService.Modules.<Name>        (when the folder exists)
	Those entries are GENERATED: every kit module (packages/kits/*/*) in every project, and an
	example module (examples/modules/<x>) in projects inside its own folder (its fixture games)
	and (v1.4.0) in any project that maps it (ReplicatedStorage.Modules.<Name> present: opt-in). Every other child of the two Modules folders is the project's own (the game module's
	server part, a game-local module) and is kept as written. The pre-v1.3.1 `Kits` folders are
	removed.

	JSON is parsed preserving key order and written back with 2-space indents, so a project only
	changes where the generated entries change.

	SyncProjects.decode(text) -> node          ordered JSON (objects: { keys, vals })
	SyncProjects.encode(node) -> text          pretty JSON + trailing newline
	SyncProjects.relative(fromDir, path) -> string    "../../" .. path for a repo-relative path
	SyncProjects.sync(projectPath, text, entries) -> (newText, changes { string })
	  entries = ModuleDiscovery.discover(fs)
]]

local SyncProjects = {}

local NULL = setmetatable({}, {
	__tostring = function()
		return "null"
	end,
})
SyncProjects.NULL = NULL

local function newObject(): any
	return { __object = true, keys = {}, vals = {} }
end
SyncProjects.newObject = newObject

local function set(obj: any, key: string, value: any)
	if obj.vals[key] == nil then
		table.insert(obj.keys, key)
	end
	obj.vals[key] = value
end
SyncProjects.set = set

local function remove(obj: any, key: string)
	if obj.vals[key] == nil then
		return
	end
	obj.vals[key] = nil
	local i = table.find(obj.keys, key)
	if i then
		table.remove(obj.keys, i)
	end
end

-- A plain decoded table -> an ordered node ("$" keys first, then alphabetical).
function SyncProjects.toOrdered(value: any): any
	if type(value) ~= "table" then
		return value
	end
	if #value > 0 then
		local arr = { __array = true, items = {} }
		for _, v in value do
			table.insert(arr.items, SyncProjects.toOrdered(v))
		end
		return arr
	end
	local keys = {}
	for k in value do
		table.insert(keys, k)
	end
	table.sort(keys, function(a: string, b: string): boolean
		local da, db = string.sub(a, 1, 1) == "$", string.sub(b, 1, 1) == "$"
		if da ~= db then
			return da
		end
		return a < b
	end)
	local obj = newObject()
	for _, k in keys do
		set(obj, k, SyncProjects.toOrdered(value[k]))
	end
	return obj
end

-- decode ------------------------------------------------------------------------------------------

function SyncProjects.decode(text: string): any
	local pos = 1
	local function fail(msg: string)
		error(`sync-projects: bad JSON at {pos}: {msg}`, 0)
	end
	local function skip()
		pos = string.find(text, "[^%s]", pos) or (#text + 1)
	end
	local value
	local function str(): string
		local out = {}
		pos += 1
		while true do
			local c = string.sub(text, pos, pos)
			if c == "" then
				fail("unterminated string")
			elseif c == '"' then
				pos += 1
				break
			elseif c == "\\" then
				local n = string.sub(text, pos + 1, pos + 1)
				local map = {
					n = "\n",
					t = "\t",
					r = "\r",
					b = "\b",
					f = "\f",
					['"'] = '"',
					["\\"] = "\\",
					["/"] = "/",
				}
				if map[n] then
					table.insert(out, map[n])
					pos += 2
				elseif n == "u" then
					local hex = string.sub(text, pos + 2, pos + 5)
					table.insert(out, utf8.char(tonumber(hex, 16) :: number))
					pos += 6
				else
					fail("bad escape")
				end
			else
				table.insert(out, c)
				pos += 1
			end
		end
		return table.concat(out)
	end
	value = function(): any
		skip()
		local c = string.sub(text, pos, pos)
		if c == "{" then
			local obj = newObject()
			pos += 1
			skip()
			if string.sub(text, pos, pos) == "}" then
				pos += 1
				return obj
			end
			while true do
				skip()
				if string.sub(text, pos, pos) ~= '"' then
					fail("expected a key")
				end
				local key = str()
				skip()
				if string.sub(text, pos, pos) ~= ":" then
					fail("expected ':'")
				end
				pos += 1
				set(obj, key, value())
				skip()
				local d = string.sub(text, pos, pos)
				pos += 1
				if d == "}" then
					return obj
				elseif d ~= "," then
					fail("expected ',' or '}'")
				end
			end
		elseif c == "[" then
			local arr = { __array = true, items = {} }
			pos += 1
			skip()
			if string.sub(text, pos, pos) == "]" then
				pos += 1
				return arr
			end
			while true do
				table.insert(arr.items, value())
				skip()
				local d = string.sub(text, pos, pos)
				pos += 1
				if d == "]" then
					return arr
				elseif d ~= "," then
					fail("expected ',' or ']'")
				end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(text, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif string.sub(text, pos, pos + 4) == "false" then
			pos += 5
			return false
		elseif string.sub(text, pos, pos + 3) == "null" then
			pos += 4
			return NULL
		else
			local num = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if num == nil or num == "" then
				fail("unexpected character '" .. c .. "'")
			end
			pos += #num
			return tonumber(num)
		end
	end
	local out = value()
	skip()
	if pos <= #text then
		fail("trailing characters")
	end
	return out
end

-- encode ------------------------------------------------------------------------------------------

local function quote(s: string): string
	local escaped = string.gsub(s, '[%c"\\]', function(c: string): string
		local map = { ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r", ['"'] = '\\"', ["\\"] = "\\\\" }
		return map[c] or string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. escaped .. '"'
end

local function encodeValue(v: any, indent: string): string
	if v == NULL then
		return "null"
	elseif type(v) == "string" then
		return quote(v)
	elseif type(v) == "number" then
		if v == math.floor(v) then
			return string.format("%d", v)
		end
		return tostring(v)
	elseif type(v) == "boolean" then
		return tostring(v)
	elseif type(v) == "table" and v.__array then
		if #v.items == 0 then
			return "[]"
		end
		local inner = indent .. "  "
		local parts = {}
		for _, item in v.items do
			table.insert(parts, inner .. encodeValue(item, inner))
		end
		return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
	elseif type(v) == "table" and v.__object then
		if #v.keys == 0 then
			return "{}"
		end
		local inner = indent .. "  "
		local parts = {}
		for _, k in v.keys do
			table.insert(parts, inner .. quote(k) .. ": " .. encodeValue(v.vals[k], inner))
		end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
	end
	error("sync-projects: cannot encode " .. typeof(v), 0)
end

function SyncProjects.encode(node: any): string
	return encodeValue(node, "") .. "\n"
end

-- sync --------------------------------------------------------------------------------------------

function SyncProjects.relative(fromDir: string, path: string): string
	local depth = 0
	for _ in string.gmatch(fromDir, "[^/]+") do
		depth += 1
	end
	return string.rep("../", depth) .. path
end

local function pathNode(path: string): any
	local node = newObject()
	set(node, "$path", path)
	return node
end

-- The generated entries a project gets: every kit module; an example module inside its folder, or
-- (added in v1.4.0) in any project that already maps it under ReplicatedStorage.Modules.<Name>
-- (`mapped[name]`: the project opts in; its entries are then generated like a kit's).
function SyncProjects.entriesFor(
	projectPath: string,
	entries: { any },
	mapped: { [string]: boolean }?
): { any }
	local out = {}
	for _, entry in entries do
		if
			entry.kit ~= nil
			or string.sub(projectPath, 1, #entry.dir + 1) == entry.dir .. "/"
			or (mapped ~= nil and mapped[entry.name] == true)
		then
			table.insert(out, entry)
		end
	end
	return out
end

function SyncProjects.sync(projectPath: string, text: string, entries: { any }): (string, { string })
	local dir = string.match(projectPath, "^(.*)/[^/]+$") or "."
	local project = SyncProjects.decode(text)
	local changes = {}
	local tree = project.vals.tree
	assert(type(tree) == "table" and tree.__object, `{projectPath}: no "tree"`)
	local mapped = {}
	local rsNode = tree.vals.ReplicatedStorage
	local rsModules = rsNode and rsNode.vals and rsNode.vals.Modules
	if rsModules and rsModules.keys then
		for _, key in rsModules.keys do
			mapped[key] = true
		end
	end
	local generated = SyncProjects.entriesFor(projectPath, entries, mapped)
	-- names a generated entry may take (any discovered module: a project can't own a kit's name)
	local reserved = {}
	for _, entry in entries do
		reserved[entry.name] = true
	end
	for _, serviceName in { "ReplicatedStorage", "ServerScriptService" } do
		local service = tree.vals[serviceName]
		if service == nil then
			service = newObject()
			set(tree, serviceName, service)
		end
		if service.vals.Kits ~= nil then
			remove(service, "Kits")
			table.insert(changes, `{serviceName}.Kits removed`)
		end
		local modules = service.vals.Modules
		if modules == nil then
			modules = newObject()
			set(modules, "$className", "Folder")
			set(service, "Modules", modules)
		end
		local rebuilt = newObject()
		-- the project's own entries first, in their order; generated names are dropped here
		for _, key in modules.keys do
			if string.sub(key, 1, 1) == "$" or not reserved[key] then
				set(rebuilt, key, modules.vals[key])
			end
		end
		for _, entry in generated do
			if serviceName == "ReplicatedStorage" then
				local holder = newObject()
				set(holder, "$className", "Folder")
				set(holder, "module", pathNode(SyncProjects.relative(dir, entry.module)))
				if entry.client then
					set(holder, "client", pathNode(SyncProjects.relative(dir, entry.client)))
				end
				if entry.shared then
					set(holder, "shared", pathNode(SyncProjects.relative(dir, entry.shared)))
				end
				if entry.migrations then
					set(holder, "migrations", pathNode(SyncProjects.relative(dir, entry.migrations)))
				end
				set(rebuilt, entry.name, holder)
			elseif entry.server then
				set(rebuilt, entry.name, pathNode(SyncProjects.relative(dir, entry.server)))
			end
		end
		service.vals.Modules = rebuilt
	end
	local out = SyncProjects.encode(project)
	if out ~= text and #changes == 0 then
		table.insert(changes, "generated Modules entries updated")
	end
	return out, changes
end

return SyncProjects
