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
	SyncProjects.sync(projectPath, text, entries, opts?) -> (newText, changes { string })
	  entries = ModuleDiscovery.discover(fs)
	  opts = { localization = boolean? }   (v1.7.0) the project's game has src/shared/Localization:
	    the tree maps it as LocalizationService ("$path": "src/shared/Localization", so its CSV files
	    become LocalizationTables the engine's translators see); without the folder a mapping this
	    tool wrote is removed (a hand-written LocalizationService node is kept)

	(v1.7.0, module-api.md §23.1, docs/framework/kits/environments.md) Environments.luau:
	SyncProjects.environments(deployText, label?) -> (luauText?, errors { string })
	  the game's src/shared/Config/Environments.luau from its deploy.json: test / live place ids,
	  live universe id, and the test universe id only when it differs from the live one (a test
	  place inside the live experience is told apart by its place id). Placeholder ids (0,
	  negative, fractional, strings) are left out. Equal real test and live place ids are an error
	  (that place would be both). SyncProjects.ENV_HEADER is the generated header.
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
	for part in string.gmatch(fromDir, "[^/]+") do
		-- (v1.5.0) "." is the project root itself (a single-game project's root game)
		if part ~= "." then
			depth += 1
		end
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

-- environments ------------------------------------------------------------------------------------

SyncProjects.ENV_PATH = "src/shared/Config/Environments.luau"
SyncProjects.LOCALIZATION_PATH = "src/shared/Localization"
SyncProjects.ENV_HEADER = table.concat({
	"--!strict",
	"-- generated by tools/sync-projects from deploy.json: do not edit by hand.",
	"-- The test and live place / universe ids this game runs in (docs/framework/kits/environments.md).",
	"-- Placeholder ids are left out; an unlisted place is treated as live.",
}, "\n")

local function realId(v: any): number?
	if type(v) == "number" and v == v and v >= 1 and v % 1 == 0 and v < 2 ^ 53 then
		return v
	end
	return nil
end

local function field(node: any, key: string): any
	if type(node) == "table" and node.__object then
		return node.vals[key]
	end
	return nil
end

function SyncProjects.environments(deployText: string, label: string?): (string?, { string })
	local where = label or "deploy.json"
	local ok, deploy = pcall(SyncProjects.decode, deployText)
	if not ok then
		return nil, { `{where}: {tostring(deploy)}` }
	end
	local ids = {}
	for _, side in { "test", "live" } do
		local node = field(deploy, side)
		ids[side] = { place = realId(field(node, "placeId")), universe = realId(field(node, "universeId")) }
	end
	local errors = {}
	if ids.test.place ~= nil and ids.test.place == ids.live.place then
		table.insert(
			errors,
			`{where}: test.placeId and live.placeId are both {string.format("%d", ids.test.place)}; the test place must be a different place`
		)
		return nil, errors
	end
	local function list(id: number?): string?
		return if id ~= nil then `\{ {string.format("%d", id)} }` else nil
	end
	local lines = {}
	for _, side in { "test", "live" } do
		local parts = {}
		local place = list(ids[side].place)
		if place then
			table.insert(parts, `placeIds = {place}`)
		end
		local universe = ids[side].universe
		if side == "test" and universe ~= nil and universe == ids.live.universe then
			universe = nil -- the test place lives in the live experience: its place id tells it apart
		end
		local uni = list(universe)
		if uni then
			table.insert(parts, `universeIds = {uni}`)
		end
		if #parts > 0 then
			table.insert(lines, `\t{side} = \{ {table.concat(parts, ", ")} },`)
		end
	end
	local body = if #lines == 0 then "return {}" else "return {\n" .. table.concat(lines, "\n") .. "\n}"
	return SyncProjects.ENV_HEADER .. "\n" .. body .. "\n", errors
end

-- (v1.7.0) LocalizationService <- src/shared/Localization (opts.localization: the folder exists)
local function syncLocalization(tree: any, want: boolean, changes: { string })
	local node = tree.vals.LocalizationService
	if want then
		if node == nil then
			node = newObject()
			set(tree, "LocalizationService", node)
		end
		if node.vals["$path"] ~= SyncProjects.LOCALIZATION_PATH then
			set(node, "$path", SyncProjects.LOCALIZATION_PATH)
			table.insert(changes, "LocalizationService mapped to " .. SyncProjects.LOCALIZATION_PATH)
		end
	elseif node ~= nil and node.vals["$path"] == SyncProjects.LOCALIZATION_PATH then
		remove(node, "$path")
		if #node.keys == 0 then
			remove(tree, "LocalizationService")
		end
		table.insert(
			changes,
			"LocalizationService mapping removed (no " .. SyncProjects.LOCALIZATION_PATH .. ")"
		)
	end
end

function SyncProjects.sync(
	projectPath: string,
	text: string,
	entries: { any },
	opts: any?
): (string, { string })
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
	syncLocalization(tree, type(opts) == "table" and opts.localization == true, changes)
	local out = SyncProjects.encode(project)
	if out ~= text and #changes == 0 then
		table.insert(changes, "generated Modules entries updated")
	end
	return out, changes
end

return SyncProjects
