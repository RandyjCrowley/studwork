--!nocheck
--[[
	tools/lune/AdoptAudit.luau (StudWork v1.6.0, docs/framework/adopting.md §1): the audit behind
	tools/adopt --audit / --verify (and the report of --from-place).

	Zero requires: every function takes `env` = { fs, serde, roblox, process, Scan (AdoptScan),
	version = "x.y.z" } (tools/lune/adopt.luau builds it; specs build their own).

	  Audit.loadProject(env, absPath) -> project?, err?   a Rojo repo (folder with a *.project.json,
	                                                      or the project file) or a .rbxl/.rbxlx
	  Audit.build(env, projects, reportDir) -> report     the report table (schema of §1)
	  Audit.encodeJson(report) / Audit.markdown(report)   the two report files' text
	  Audit.run(env, absPaths, { write = bool }) -> report?, err?, reportDir
	  Audit.verifyIssues(env, absPath) -> { string }?, err?   what --verify still refuses
	  Audit.CONTAINERS, Audit.codeContainer(inst)         the code containers (shared with --from-place)

	Read-only except the two report files (written only by run with write = true). Paths in the
	report are relative to the (first) project's root; nothing absolute is written.
]]

local Audit = {}

-- vendored save-library implementations, by lower-case file name (no extension)
Audit.LIBRARY_FILES = { profileservice = true, profilestore = true, datastore2 = true }

Audit.REPORT_JSON = "studwork-adopt-report.json"
Audit.REPORT_MD = "studwork-adopt-report.md"
Audit.MANIFEST = ".studwork-from-place.json"
Audit.LEGACY_LIST = "studwork-legacy.json"

-- the code containers --from-place extracts (instance names under the DataModel)
Audit.CONTAINERS = {
	{ "ServerScriptService" },
	{ "ServerStorage" },
	{ "ReplicatedStorage" },
	{ "ReplicatedFirst" },
	{ "StarterPlayer", "StarterPlayerScripts" },
	{ "StarterPlayer", "StarterCharacterScripts" },
}

local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }
Audit.SCRIPT_CLASSES = SCRIPT_CLASSES
local SERVER_CONTAINERS = { ServerScriptService = true, ServerStorage = true }
local CLIENT_CONTAINERS =
	{ StarterPlayer = true, StarterGui = true, ReplicatedFirst = true, StarterPack = true }
-- $path folders the audit never scans: dependencies and the StudWork submodule itself
local SKIP_SEGMENTS = { Packages = true, ServerPackages = true, DevPackages = true, node_modules = true }

local LEVELS = { "critical", "high", "medium", "low" }
local LEVEL_RANK = { critical = 1, high = 2, medium = 3, low = 4 }
Audit.LEVELS = LEVELS

Audit.NULL = setmetatable({}, {
	__tostring = function()
		return "null"
	end,
})
local NULL = Audit.NULL
local ARRAY = { __array = true }
local function A(t)
	return setmetatable(t or {}, ARRAY)
end
Audit.array = A
local OBJECT = { __object = true }
-- a table that encodes as a JSON object even when empty
function Audit.object(t)
	return setmetatable(t or {}, OBJECT)
end

--------------------------------------------------------------------------------
-- paths
--------------------------------------------------------------------------------

function Audit.normalize(path: string): string
	local abs = string.sub(path, 1, 1) == "/"
	local parts = {}
	for seg in string.gmatch(path, "[^/]+") do
		if seg == "." then
			continue
		elseif seg == ".." then
			if #parts > 0 and parts[#parts] ~= ".." then
				table.remove(parts)
			elseif not abs then
				table.insert(parts, "..")
			end
		else
			table.insert(parts, seg)
		end
	end
	local out = table.concat(parts, "/")
	if abs then
		return "/" .. out
	end
	return if out == "" then "." else out
end

function Audit.join(a: string, b: string): string
	if string.sub(b, 1, 1) == "/" then
		return Audit.normalize(b)
	end
	return Audit.normalize(a .. "/" .. b)
end

-- relative path from folder `from` to `to` (both absolute)
function Audit.relative(from: string, to: string): string
	local f, t = {}, {}
	for s in string.gmatch(Audit.normalize(from), "[^/]+") do
		table.insert(f, s)
	end
	for s in string.gmatch(Audit.normalize(to), "[^/]+") do
		table.insert(t, s)
	end
	local i = 1
	while i <= #f and i <= #t and f[i] == t[i] do
		i += 1
	end
	local out = {}
	for _ = i, #f do
		table.insert(out, "..")
	end
	for k = i, #t do
		table.insert(out, t[k])
	end
	return if #out == 0 then "." else table.concat(out, "/")
end

local function dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or "."
end
local function basename(path: string): string
	return string.match(path, "([^/]+)$") or path
end
Audit.dirname = dirname
Audit.basename = basename

local function isPlaceFile(path: string): boolean
	local low = string.lower(path)
	return string.match(low, "%.rbxl$") ~= nil or string.match(low, "%.rbxlx$") ~= nil
end
Audit.isPlaceFile = isPlaceFile

local function readJson(env, path: string): any?
	local ok, text = pcall(env.fs.readFile, path)
	if not ok then
		return nil
	end
	local ok2, value = pcall(env.serde.decode, "json", text)
	return if ok2 then value else nil
end

local function globToPattern(glob: string): string
	local p = string.gsub(glob, "[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
	p = string.gsub(p, "%*%*/", "\1")
	p = string.gsub(p, "%*%*", "\2")
	p = string.gsub(p, "%*", "[^/]*")
	p = string.gsub(p, "\1", ".-")
	p = string.gsub(p, "\2", ".*")
	return "^" .. p .. "$"
end

--------------------------------------------------------------------------------
-- collecting scripts: Rojo projects
--------------------------------------------------------------------------------

local SCRIPT_SUFFIXES = {
	{ ".server.luau", "Script" },
	{ ".server.lua", "Script" },
	{ ".client.luau", "LocalScript" },
	{ ".client.lua", "LocalScript" },
	{ ".luau", "ModuleScript" },
	{ ".lua", "ModuleScript" },
}

-- (v1.6.0 dogfood r2) generated code is never audited: Blink's output (server/Net.luau and
-- client/Net.luau of a module with a net.blink, in that folder or the one above) and any
-- Generated*.luau. Its remotes and _G use are Blink's, not the old game's.
function Audit.isGenerated(fs, abs: string): boolean
	local base = string.match(abs, "([^/]+)$") or abs
	if string.match(base, "^Generated.*%.luau?$") then
		return true
	end
	if base == "Net.luau" or base == "Net.lua" then
		local dir = string.match(abs, "^(.*)/[^/]+$") or "."
		local up = string.match(dir, "^(.*)/[^/]+$") or "."
		return fs.isFile(dir .. "/net.blink") or fs.isFile(up .. "/net.blink")
	end
	return false
end

local function scriptKind(fileName: string): (string?, string?)
	for _, s in SCRIPT_SUFFIXES do
		if #fileName > #s[1] and string.sub(fileName, -#s[1]) == s[1] then
			return s[2], string.sub(fileName, 1, -#s[1] - 1)
		end
	end
	return nil, nil
end

local function sideOf(class: string, instPath: string, runContext: string?): string
	if class == "LocalScript" then
		return "client"
	end
	local top = string.match(instPath, "^([^%.]+)") or ""
	if class == "Script" then
		if runContext == "Client" then
			return "client"
		end
		return "server"
	end
	if SERVER_CONTAINERS[top] then
		return "server"
	elseif CLIENT_CONTAINERS[top] then
		return "client"
	end
	return "shared"
end
Audit.sideOf = sideOf

local function modelRemotes(env, node, instPath: string, out)
	if type(node) ~= "table" then
		return
	end
	local class = node.className or node.ClassName
	if class and env.Scan.REMOTE_CLASSES[class] then
		table.insert(
			out,
			{ name = basename(string.gsub(instPath, "%.", "/")), class = class, path = instPath }
		)
	end
	for _, child in node.children or node.Children or {} do
		local name = child.name or child.Name or "?"
		modelRemotes(env, child, instPath .. "." .. name, out)
	end
end

local function instanceRemotes(env, inst, instPath: string, out)
	if env.Scan.REMOTE_CLASSES[inst.ClassName] then
		table.insert(out, { name = inst.Name, class = inst.ClassName, path = instPath })
	end
	for _, child in inst:GetChildren() do
		instanceRemotes(env, child, instPath .. "." .. child.Name, out)
	end
end

local function loadRojo(env, root: string, projectFile: string)
	local fs = env.fs
	local project = readJson(env, root .. "/" .. projectFile)
	if type(project) ~= "table" or type(project.tree) ~= "table" then
		return nil, "can't read " .. projectFile .. " (not a Rojo project file)"
	end
	local ignores = {}
	for _, g in project.globIgnorePaths or {} do
		table.insert(ignores, globToPattern(g))
	end
	local hasMarker = fs.isFile(root .. "/studwork.json")
	local p = {
		kind = "rojo",
		root = root,
		projectFile = projectFile,
		scripts = {},
		remotes = {},
		ui = {},
		external = {},
	}
	local seenFiles = {}

	local function ignored(rel: string): boolean
		for _, pat in ignores do
			if string.match(rel, pat) then
				return true
			end
		end
		return false
	end

	local function label(abs: string, ext: string?): string
		if ext then
			return "external:" .. Audit.normalize(ext .. "/" .. Audit.relative(Audit.join(root, ext), abs))
		end
		return Audit.relative(root, abs)
	end

	local function addScript(abs: string, class: string, instPath: string, ext: string?, metaPath: string?)
		if seenFiles[abs] or Audit.isGenerated(fs, abs) then
			return
		end
		seenFiles[abs] = true
		local ok, source = pcall(fs.readFile, abs)
		if not ok then
			return
		end
		local runContext = nil
		local meta = metaPath and readJson(env, metaPath)
		if type(meta) == "table" and type(meta.properties) == "table" then
			local rc = meta.properties.RunContext
			runContext = if type(rc) == "table" then rc.Enum else rc
		end
		table.insert(p.scripts, {
			path = label(abs, ext),
			class = class,
			instPath = instPath,
			side = sideOf(class, instPath, runContext),
			source = source,
		})
	end

	local walkPath
	local function walkEntry(abs: string, name: string, instParent: string, ext: string?)
		if fs.isDir(abs) then
			walkPath(abs, instParent .. "." .. name, ext)
			return
		end
		local rel = Audit.relative(root, abs)
		if ignored(rel) then
			return
		end
		local class, stem = scriptKind(name)
		if class then
			if stem == "init" then
				return -- handled by its folder
			end
			addScript(abs, class, instParent .. "." .. stem, ext, dirname(abs) .. "/" .. stem .. ".meta.json")
		elseif string.match(name, "%.model%.json$") then
			local stem2 = string.sub(name, 1, -#".model.json" - 1)
			modelRemotes(env, readJson(env, abs), instParent .. "." .. stem2, p.remotes)
		elseif string.match(name, "%.rbxmx?$") then
			local stem2 = string.match(name, "^(.*)%.rbxmx?$")
			local ok, insts = pcall(function()
				return env.roblox.deserializeModel(fs.readFile(abs))
			end)
			if ok then
				for _, inst in insts do
					instanceRemotes(env, inst, instParent .. "." .. stem2, p.remotes)
				end
			end
		end
	end

	walkPath = function(abs: string, instPath: string, ext: string?)
		local rel = Audit.relative(root, abs)
		for seg in string.gmatch(rel, "[^/]+") do
			if SKIP_SEGMENTS[seg] then
				return
			end
		end
		if hasMarker and (rel == "studwork" or string.sub(rel, 1, 9) == "studwork/") then
			return -- the StudWork submodule of an adopted project
		end
		if fs.isFile(abs) then
			local parent = string.match(instPath, "^(.*)%.[^%.]+$") or instPath
			local class = scriptKind(basename(abs))
			if class then
				addScript(abs, class, instPath, ext, nil)
			else
				walkEntry(abs, basename(abs), parent, ext)
			end
			return
		end
		if not fs.isDir(abs) then
			return
		end
		local entries = fs.readDir(abs)
		table.sort(entries)
		for _, e in entries do
			local class, stem = scriptKind(e)
			if class and stem == "init" then
				addScript(abs .. "/" .. e, class, instPath, ext, abs .. "/init.meta.json")
			end
		end
		local initMeta = readJson(env, abs .. "/init.meta.json")
		local className = if type(initMeta) == "table" then initMeta.className else nil
		if string.match(instPath, "^StarterGui%.[^%.]+$") then
			table.insert(p.ui, { path = instPath, class = className or "Folder" })
		end
		for _, e in entries do
			if string.sub(e, 1, 1) == "." or string.match(e, "%.meta%.json$") then
				continue
			end
			walkEntry(abs .. "/" .. e, e, instPath, ext)
		end
	end

	local function walkNode(node, instPath: string)
		if type(node) ~= "table" then
			return
		end
		local class = node["$className"]
		if class and env.Scan.REMOTE_CLASSES[class] then
			table.insert(
				p.remotes,
				{ name = basename(string.gsub(instPath, "%.", "/")), class = class, path = instPath }
			)
		end
		local path = node["$path"]
		if type(path) == "table" then
			path = path.optional
		end
		if type(path) == "string" then
			local abs = Audit.join(root, path)
			local rel = Audit.relative(root, abs)
			local ext = nil
			if string.sub(rel, 1, 3) == "../" or rel == ".." then
				ext = path
				table.insert(p.external, "external:" .. path)
			end
			if fs.isFile(abs) then
				local name = basename(abs)
				local cls = scriptKind(name)
				if cls then
					addScript(abs, cls, instPath, ext, nil)
				elseif string.match(name, "%.model%.json$") then
					modelRemotes(env, readJson(env, abs), instPath, p.remotes)
				end
			else
				walkPath(abs, instPath, ext)
			end
		end
		local keys = {}
		for k in node do
			if string.sub(k, 1, 1) ~= "$" then
				table.insert(keys, k)
			end
		end
		table.sort(keys)
		for _, k in keys do
			local childPath = if instPath == "" then k else instPath .. "." .. k
			if instPath == "StarterGui" and type(node[k]) == "table" and node[k]["$path"] == nil then
				table.insert(p.ui, { path = childPath, class = node[k]["$className"] or "Folder" })
			end
			walkNode(node[k], childPath)
		end
	end

	walkNode(project.tree, "")
	-- the place file a --from-place project (or an adopted place-file game) still has
	local marker = readJson(env, root .. "/studwork.json")
	local manifest = readJson(env, root .. "/" .. Audit.MANIFEST)
	local placeRel = (type(marker) == "table" and type(marker.placeFile) == "string" and marker.placeFile)
		or (type(manifest) == "table" and type(manifest.placeFile) == "string" and manifest.placeFile)
		or nil
	if placeRel then
		p.placeFile = Audit.join(root, placeRel)
	end
	p.manifest = manifest
	return p
end

--------------------------------------------------------------------------------
-- collecting scripts: place files
--------------------------------------------------------------------------------

local function instPathOf(inst): string
	local names = {}
	local cur = inst
	while cur ~= nil and cur.ClassName ~= "DataModel" do
		table.insert(names, 1, cur.Name)
		cur = cur.Parent
	end
	return table.concat(names, ".")
end
Audit.instPathOf = instPathOf

-- the index of the code container an instance sits in (only Folders and scripts between them),
-- or nil: then --from-place leaves it in the place (notExtracted)
function Audit.codeContainer(inst): number?
	local chain = {}
	local cur = inst.Parent
	while cur ~= nil and cur.ClassName ~= "DataModel" do
		table.insert(chain, 1, cur)
		cur = cur.Parent
	end
	for idx, c in Audit.CONTAINERS do
		if #chain < #c then
			continue
		end
		local match = true
		for k, name in c do
			if chain[k].Name ~= name then
				match = false
				break
			end
		end
		if match then
			for k = #c + 1, #chain do
				local cls = chain[k].ClassName
				if cls ~= "Folder" and not SCRIPT_CLASSES[cls] then
					return nil
				end
			end
			return idx
		end
	end
	return nil
end

-- (v1.6.0 dogfood r3) the scripts --from-place extracts, as the instances to strip from the place
-- afterwards: every script in a code container with no script above it (a script's own child
-- scripts go with it), full dotted paths, sorted
function Audit.extractedPaths(place): { string }
	local out = {}
	local function walk(inst)
		for _, child in inst:GetChildren() do
			if SCRIPT_CLASSES[child.ClassName] then
				if Audit.codeContainer(child) ~= nil then
					table.insert(out, instPathOf(child))
				end
			else
				walk(child)
			end
		end
	end
	walk(place)
	table.sort(out)
	return out
end

-- every instance under `root` whose full dotted path is `path` (an instance name may hold dots)
function Audit.findPath(root, path: string): { any }
	local out = {}
	local function walk(node, rest: string)
		for _, child in node:GetChildren() do
			local name = child.Name
			if rest == name then
				table.insert(out, child)
			elseif string.sub(rest, 1, #name + 1) == name .. "." then
				walk(child, string.sub(rest, #name + 2))
			end
		end
	end
	if path ~= "" then
		walk(root, path)
	end
	return out
end

local function enumName(v): string?
	if v == nil then
		return nil
	end
	local ok, name = pcall(function()
		return v.Name
	end)
	return if ok then name else tostring(v)
end

function Audit.placeScripts(env, place)
	local scripts, remotes, ui = {}, {}, {}
	local function walk(inst)
		for _, child in inst:GetChildren() do
			local cls = child.ClassName
			if SCRIPT_CLASSES[cls] then
				local path = instPathOf(child)
				local rc = nil
				if cls == "Script" then
					local ok, v = pcall(function()
						return child.RunContext
					end)
					rc = if ok then enumName(v) else nil
				end
				local ok, source = pcall(function()
					return child.Source
				end)
				table.insert(scripts, {
					path = path,
					class = cls,
					instPath = path,
					side = sideOf(cls, path, rc),
					source = if ok and type(source) == "string" then source else "",
					extract = Audit.codeContainer(child) ~= nil,
				})
			elseif env.Scan.REMOTE_CLASSES[cls] then
				table.insert(remotes, { name = child.Name, class = cls, path = instPathOf(child) })
			end
			walk(child)
		end
	end
	walk(place)
	local sg = place:FindFirstChildOfClass("StarterGui")
	if sg then
		for _, gui in sg:GetChildren() do
			table.insert(ui, { path = instPathOf(gui), class = gui.ClassName, children = #gui:GetChildren() })
		end
	end
	return scripts, remotes, ui
end

local function readPlace(env, abs: string)
	local ok, place = pcall(function()
		return env.roblox.deserializePlace(env.fs.readFile(abs))
	end)
	if not ok then
		return nil, "can't read the place file " .. basename(abs) .. ": " .. tostring(place)
	end
	return place
end
Audit.readPlace = readPlace

--------------------------------------------------------------------------------
-- loading a project
--------------------------------------------------------------------------------

function Audit.loadProject(env, absPath: string)
	local fs = env.fs
	absPath = Audit.normalize(absPath)
	if isPlaceFile(absPath) then
		if not fs.isFile(absPath) then
			return nil, "no such place file: " .. basename(absPath)
		end
		local place, err = readPlace(env, absPath)
		if place == nil then
			return nil, err
		end
		local scripts, remotes, ui = Audit.placeScripts(env, place)
		local notExtracted = {}
		for _, s in scripts do
			if not s.extract then
				table.insert(notExtracted, s)
			end
		end
		return {
			kind = "place",
			root = dirname(absPath),
			projectFile = nil,
			placeFile = absPath,
			scripts = scripts,
			remotes = remotes,
			ui = ui,
			external = {},
			notExtracted = notExtracted,
		}
	end
	local root, projectFile
	if fs.isFile(absPath) and string.match(absPath, "%.project%.json$") then
		root, projectFile = dirname(absPath), basename(absPath)
	elseif fs.isDir(absPath) then
		root = absPath
		if fs.isFile(absPath .. "/default.project.json") then
			projectFile = "default.project.json"
		else
			local entries = fs.readDir(absPath)
			table.sort(entries)
			for _, e in entries do
				if string.match(e, "%.project%.json$") then
					projectFile = e
					break
				end
			end
		end
		if projectFile == nil then
			return nil,
				"no *.project.json in " .. basename(absPath) .. " (give a Rojo repo or a .rbxl/.rbxlx)"
		end
	else
		return nil, "no such project: " .. basename(absPath)
	end
	local p, err = loadRojo(env, root, projectFile)
	if p == nil then
		return nil, err
	end
	p.notExtracted = {}
	p.placeDuplicates = {}
	if p.placeFile then
		if fs.isFile(p.placeFile) then
			local place, perr = readPlace(env, p.placeFile)
			if place == nil then
				return nil, perr
			end
			local scripts, remotes, ui = Audit.placeScripts(env, place)
			for _, s in scripts do
				if not s.extract then
					s.path = "place:" .. s.path
					table.insert(p.notExtracted, s)
				end
			end
			-- (v1.6.0 dogfood r3) the extracted scripts the place still holds: syncing the project
			-- into it would run the old code next to its project copy. The manifest's `extracted`
			-- (written by --from-place); an older manifest without it: every script --from-place
			-- would extract (the same rule)
			local recorded = if type(p.manifest) == "table" and type(p.manifest.extracted) == "table"
				then p.manifest.extracted
				else Audit.extractedPaths(place)
			local seenDup = {}
			for _, path in recorded do
				if type(path) == "string" and not seenDup[path] then
					seenDup[path] = true
					local found = Audit.findPath(place, path)
					if #found > 0 then
						table.insert(p.placeDuplicates, { path = path, class = found[1].ClassName })
					end
				end
			end
			for _, r in remotes do
				table.insert(p.remotes, r)
			end
			for _, u in ui do
				table.insert(p.ui, u)
			end
		else
			p.placeMissing = true
		end
	end
	return p
end

--------------------------------------------------------------------------------
-- the report
--------------------------------------------------------------------------------

local function sortBy(list, ...)
	local keys = { ... }
	table.sort(list, function(a, b)
		for _, k in keys do
			local x, y = a[k], b[k]
			if x == NULL then
				x = nil
			end
			if y == NULL then
				y = nil
			end
			if x ~= y then
				if x == nil then
					return true
				elseif y == nil then
					return false
				end
				if type(x) ~= type(y) then
					return tostring(x) < tostring(y)
				end
				return x < y
			end
		end
		return false
	end)
	return list
end

local function uniqSorted(list)
	local set, out = {}, A()
	for _, v in list do
		if not set[v] then
			set[v] = true
			table.insert(out, v)
		end
	end
	table.sort(out)
	return out
end

local function findingsOf(scan)
	local f = A()
	for _, d in scan.datastores do
		table.insert(f, { kind = "datastore", line = d.line, detail = "GetDataStore " .. d.name })
		for _, c in d.calls do
			table.insert(f, { kind = "datastore", line = c.line, detail = c.op })
		end
	end
	for _, l in scan.libraries do
		table.insert(f, { kind = "library", line = l.line, detail = l.name .. " " .. l.store })
	end
	for _, r in scan.purchases.processReceipt do
		table.insert(f, { kind = "processReceipt", line = r.line, detail = "ProcessReceipt" })
	end
	for _, pr in scan.purchases.prompts do
		table.insert(f, { kind = "prompt", line = pr.line, detail = pr.kind })
	end
	for _, o in scan.purchases.ownership do
		table.insert(f, { kind = "ownership", line = o.line, detail = o.kind })
	end
	for _, h in scan.remotes.handlers do
		table.insert(f, { kind = "remote", line = h.line, detail = h.kind .. " " .. h.name })
	end
	for _, g in scan.globals do
		table.insert(f, { kind = "global", line = g.line, detail = g.kind })
	end
	return sortBy(f, "line", "kind", "detail")
end

-- true when a notExtracted script's findings use DataStores, ProcessReceipt or product prompts
local function unsafeFindings(findings): boolean
	for _, f in findings do
		if f.kind == "datastore" or f.kind == "library" or f.kind == "processReceipt" then
			return true
		end
		if
			f.kind == "prompt"
			and (f.detail == "PromptProductPurchase" or f.detail == "PromptProductPurchaseFinished")
		then
			return true
		end
	end
	return false
end
Audit.unsafeFindings = unsafeFindings

local function looksPlayerish(text: string?): boolean
	if text == nil then
		return false
	end
	local low = string.lower(text)
	return string.find(low, "player") ~= nil
		or string.find(low, "plr") ~= nil
		or string.find(low, "user") ~= nil
end

function Audit.build(env, projects, reportDir: string)
	local Scan = env.Scan
	local report = {
		reportVersion = 1,
		tool = "studwork-adopt",
		studwork = env.version or "1.6.0",
		projects = A(),
		scripts = A(),
		notExtracted = A(),
		placeDuplicates = A(),
		datastores = A(),
		libraries = A(),
		sharedStores = A(),
		purchases = {
			processReceipt = A(),
			products = A(),
			passes = A(),
			prompts = A(),
			ownership = A(),
		},
		remotes = A(),
		leaderstats = A(),
		ui = A(),
		globals = A(),
		risks = A(),
		plan = A(),
	}
	local risks = report.risks
	local riskSeen = {}
	local function risk(
		kind: string,
		level: string,
		message: string,
		file: string?,
		line: number?,
		extra: string?
	)
		local id = kind
			.. ":"
			.. (file or "-")
			.. ":"
			.. tostring(line or 0)
			.. (if extra then ":" .. extra else "")
		if riskSeen[id] then
			return
		end
		riskSeen[id] = true
		table.insert(
			risks,
			{ id = id, level = level, message = message, file = file or NULL, line = line or NULL }
		)
	end

	local storeMap = {} -- key -> datastore entry
	local storeProjects = {} -- name -> { [projectLabel] = { writes = bool } }
	local remoteMap = {}
	local writers = {} -- store|key -> { [file] = line }
	local fileScan = {} -- file -> { scan, script }
	local productMap = {}

	local function noteStore(name: string, proj: string, writes: boolean)
		if name == Scan.DYNAMIC then
			return
		end
		storeProjects[name] = storeProjects[name] or {}
		local e = storeProjects[name][proj] or { writes = false }
		e.writes = e.writes or writes
		storeProjects[name][proj] = e
	end

	local function remoteEntry(name: string, class: string?, path: string?)
		local r = remoteMap[name]
		if r == nil then
			r = {
				name = name,
				class = class or "RemoteEvent",
				path = path or "<unresolved>",
				handlers = A(),
				fires = A(),
			}
			remoteMap[name] = r
			table.insert(report.remotes, r)
		else
			if class and r.path == "<unresolved>" then
				r.class = class
			end
			if path and r.path == "<unresolved>" then
				r.path = path
			end
		end
		return r
	end

	for _, p in projects do
		local projLabel = Audit.relative(reportDir, p.root)
		local function fileLabel(path: string): string
			if projLabel == "." or string.sub(path, 1, 9) == "external:" then
				return path
			end
			return projLabel .. "/" .. path
		end
		table.insert(report.projects, {
			kind = p.kind,
			root = projLabel,
			projectFile = p.projectFile or NULL,
			placeFile = if p.placeFile then Audit.relative(p.root, p.placeFile) else NULL,
		})
		if p.placeMissing then
			risk(
				"place_missing",
				"high",
				"the place file listed for this project is missing; scripts left in it can't be checked",
				fileLabel(Audit.relative(p.root, p.placeFile)),
				nil
			)
		end
		for _, d in p.placeDuplicates or {} do
			table.insert(report.placeDuplicates, { path = d.path, class = d.class })
			risk(
				"place_duplicate",
				"high",
				"`"
					.. d.path
					.. "` was extracted into the project but is still in the place file: syncing the project into it runs the old code next to StudWork; run tools/adopt --strip-place . --extracted",
				fileLabel(Audit.relative(p.root, p.placeFile)),
				nil,
				d.path
			)
		end
		for _, r in p.remotes do
			remoteEntry(r.name, r.class, fileLabel(r.path))
		end
		for _, u in p.ui do
			local entry = { path = u.path, class = u.class, scripts = A() }
			if u.children then
				entry.children = u.children
			end
			for _, s in p.scripts do
				if string.sub(s.instPath, 1, #u.path + 1) == u.path .. "." then
					table.insert(entry.scripts, fileLabel(s.path))
				end
			end
			for _, s in p.notExtracted do
				if p.kind == "rojo" and string.sub(s.instPath, 1, #u.path + 1) == u.path .. "." then
					table.insert(entry.scripts, fileLabel(s.path))
				end
			end
			table.sort(entry.scripts)
			table.insert(report.ui, entry)
		end

		local all = {}
		for _, s in p.scripts do
			table.insert(all, { s = s, extracted = true })
		end
		if p.kind == "rojo" then
			for _, s in p.notExtracted do
				table.insert(all, { s = s, extracted = false })
			end
		end
		local moduleSources = {}
		for _, item in all do
			if item.s.class == "ModuleScript" then
				table.insert(moduleSources, item.s.source)
			end
		end
		local constants = Scan.constants(moduleSources)
		for _, item in all do
			local s = item.s
			local file = fileLabel(s.path)
			local scan = Scan.scan(s.source, constants)
			fileScan[file] = { scan = scan, script = s }
			if item.extracted then
				table.insert(report.scripts, {
					path = file,
					class = s.class,
					side = s.side,
					lines = scan.lines,
					project = projLabel,
				})
			end
			if (p.kind == "place" and not s.extract) or not item.extracted then
				local findings = findingsOf(scan)
				table.insert(report.notExtracted, { path = file, class = s.class, findings = findings })
				if unsafeFindings(findings) then
					risk(
						"not_extracted",
						"high",
						"a script left in the place ("
							.. s.instPath
							.. ") uses DataStores or purchases; move its code into the project",
						file,
						nil
					)
				end
			end

			-- (v1.6.0 dogfood) a vendored save library's own implementation (ProfileService.lua,
			-- ProfileStore, DataStore2): its internal DataStore calls are the library's, built from
			-- runtime names by design; the game's USE of it is what the import reads. Not a risk.
			local base = string.lower(string.match(file, "([^/]+)$") or file)
			base = string.gsub(base, "%.luau?$", "")
			base = string.gsub(base, "/init$", "")
			if base == "init" then
				base = string.lower(string.match(file, "([^/]+)/init%.luau?$") or "")
			end
			if Audit.LIBRARY_FILES[base] then
				scan.datastores = {}
				scan.libraries = {}
				risk(
					"library_implementation",
					"low",
					"vendored save library ("
						.. base
						.. "): its own DataStore calls aren't audited; remove it once nothing requires it",
					file,
					nil
				)
			end

			-- datastores
			for _, d in scan.datastores do
				local key = d.name .. "|" .. tostring(d.scope) .. "|" .. d.kind
				local e = storeMap[key]
				if e == nil then
					e = {
						name = d.name,
						scope = d.scope or NULL,
						kind = d.kind,
						keyPatterns = A(),
						calls = A(),
						_projects = {},
					}
					storeMap[key] = e
					table.insert(report.datastores, e)
				end
				local writes = false
				for _, c in d.calls do
					table.insert(e.calls, { op = c.op, file = file, line = c.line, key = c.key or NULL })
					if c.key then
						table.insert(e.keyPatterns, c.key)
					end
					if Scan.WRITE_OPS[c.op] then
						writes = true
						if c.key and c.key ~= Scan.DYNAMIC then
							local wk = d.name .. "|" .. tostring(d.scope) .. "|" .. c.key
							writers[wk] = writers[wk] or {}
							writers[wk][file] = writers[wk][file] or c.line
						end
					end
					if
						c.op == "RemoveAsync"
						and (c.key == Scan.DYNAMIC or string.find(c.key or "", "{userId}", 1, true))
					then
						risk(
							"remove_player_data",
							"critical",
							"RemoveAsync on player data in store " .. d.name .. " (a save can be deleted)",
							file,
							c.line
						)
					end
					if Scan.WRITE_OPS[c.op] and c.key == Scan.DYNAMIC then
						if looksPlayerish(c.keyExpr) or looksPlayerish(d.name) then
							risk(
								"key_not_derivable",
								"critical",
								"store "
									.. d.name
									.. ": a player-save key that isn't derivable from the userId ("
									.. c.op
									.. "); the import can't find it",
								file,
								c.line
							)
						else
							risk(
								"dynamic_key",
								"medium",
								"store " .. d.name .. ": key not derivable (" .. c.op .. ")",
								file,
								c.line
							)
						end
					end
					if
						c.op == "SetAsync"
						and c.key
						and string.find(c.key, "{userId}", 1, true)
						-- a receipt history entry ({userId}_{purchaseId}) is written once
						and not string.find(c.key, "{purchaseId}", 1, true)
					then
						risk(
							"set_without_lock",
							"high",
							"SetAsync on a player save ("
								.. d.name
								.. ", "
								.. c.key
								.. ") without a session lock",
							file,
							c.line
						)
					end
					if string.match(d.name, "^PlayerData_") and c.key == "Player_{userId}" then
						risk(
							"store_collision",
							"critical",
							"store "
								.. d.name
								.. " with key Player_{userId} collides with StudWork's own save store; pick a game id that differs",
							file,
							c.line
						)
					end
				end
				if d.name == Scan.DYNAMIC then
					risk("dynamic_store", "medium", "a DataStore name built at runtime", file, d.line)
				end
				noteStore(d.name, projLabel, writes)
			end

			-- save libraries
			for _, l in scan.libraries do
				table.insert(report.libraries, {
					name = l.name,
					store = l.store,
					scope = l.scope or NULL,
					keyPattern = l.keyPattern,
					combined = A(table.clone(l.combined)),
					file = file,
					line = l.line,
				})
				noteStore(l.store, projLabel, true)
				if l.keyPattern == Scan.DYNAMIC and l.name ~= "DataStore2" then
					risk(
						"key_not_derivable",
						"critical",
						l.name .. " store " .. l.store .. ": the profile key isn't derivable from the userId",
						file,
						l.line
					)
				end
				if string.match(l.store, "^PlayerData_") and l.keyPattern == "Player_{userId}" then
					risk(
						"store_collision",
						"critical",
						"store "
							.. l.store
							.. " with key Player_{userId} collides with StudWork's own save store",
						file,
						l.line
					)
				end
			end

			-- purchases
			local pur = scan.purchases
			for _, r in pur.processReceipt do
				table.insert(
					report.purchases.processReceipt,
					{ file = file, line = r.line, historyCheck = r.historyCheck }
				)
				if not r.historyCheck then
					risk(
						"receipt_no_history",
						"critical",
						"ProcessReceipt grants without a purchase-history check (a re-delivered receipt grants twice)",
						file,
						r.line
					)
				end
			end
			for _, pr in pur.products do
				local e = productMap[pr.id]
				if e == nil then
					e = { id = pr.id, file = file, line = pr.line, sold = A(), random = false }
					productMap[pr.id] = e
					table.insert(report.purchases.products, e)
				end
				for _, f in pr.sold do
					if not table.find(e.sold, f) then
						table.insert(e.sold, f)
					end
				end
				table.sort(e.sold)
				e.random = e.random or pr.random
				if pr.writes and #pr.sold == 0 and s.side ~= "client" then
					-- (v1.6.0 dogfood r2) e.g. `_G.Stores[plr].coins:Increment(...)`: the scan
					-- can't name the field, so say so instead of a silent sold = []
					risk(
						"sold_unknown",
						"medium",
						"product "
							.. pr.id
							.. "'s handler writes save data but the audit couldn't tell which field it sells (a handle kept in a table or _G?): read the handler and decide which currency or items it sells",
						file,
						pr.line
					)
				end
				if pr.random then
					risk(
						"product_random",
						"critical",
						"product "
							.. pr.id
							.. "'s handler uses randomness (paid random item: odds must be shown)",
						file,
						pr.line
					)
				end
			end
			for _, ps in pur.passes do
				table.insert(report.purchases.passes, { id = ps.id, file = file, line = ps.line })
			end
			for _, pr in pur.prompts do
				table.insert(
					report.purchases.prompts,
					{ kind = pr.kind, id = pr.id or NULL, file = file, line = pr.line }
				)
			end
			for _, o in pur.ownership do
				table.insert(
					report.purchases.ownership,
					{ kind = o.kind, id = o.id or NULL, file = file, line = o.line }
				)
			end
			-- (v1.6.0 dogfood r2) only server code (a client's math.random for visuals sells
			-- nothing), only randomness in a function that also grants, and not twice for a
			-- product handler already rated product_random
			local sells = #pur.processReceipt > 0 or #pur.prompts > 0
			local productRandom = false
			for _, pr in pur.products do
				productRandom = productRandom or pr.random
			end
			if
				sells
				and s.side ~= "client"
				and scan.randomGrants
				and not productRandom
				and not scan.mentionsOdds
			then
				local rl = nil
				for _, pr in pur.products do
					rl = rl or pr.line
				end
				risk(
					"paid_random_no_odds",
					"high",
					"randomness next to purchases with no odds shown (paid random items must disclose odds)",
					file,
					rl
						or (pur.processReceipt[1] and pur.processReceipt[1].line)
						or (pur.prompts[1] and pur.prompts[1].line)
				)
			end

			-- remotes
			for _, c in scan.remotes.created do
				local r = remoteEntry(c.name, c.class, nil)
				if r.path == "<unresolved>" then
					r.path = file
				end
			end
			for _, h in scan.remotes.handlers do
				local cls = if h.kind == "OnServerInvoke" or h.kind == "OnClientInvoke"
					then "RemoteFunction"
					else nil
				local r = remoteEntry(h.name, cls, nil)
				table.insert(r.handlers, { kind = h.kind, file = file, line = h.line })
			end
			for _, f in scan.remotes.fires do
				if remoteMap[f.name] or f.kind ~= "Fire" then
					local r = remoteEntry(f.name, nil, nil)
					table.insert(r.fires, { kind = f.kind, file = file, line = f.line })
				end
			end
			for _, t in scan.trusts do
				risk(
					"remote_trusts_client",
					"high",
					"remote "
						.. t.name
						.. ": the handler writes the client-supplied `"
						.. t.param
						.. "`; validate it on the server",
					file,
					t.line,
					t.param
				)
			end

			-- (v1.6.0 dogfood r3) a client value passed straight into a grant/save write
			for _, t in scan.valueTrusts or {} do
				risk(
					"client_value_trusted",
					"high",
					"remote "
						.. t.name
						.. ": the handler passes the client-sent `"
						.. t.param
						.. "` into "
						.. t.method
						.. " (a grant/save write); compute the value on the server (a module action)",
					file,
					t.line,
					t.param
				)
			end

			-- leaderstats, globals, notes. (v1.6.0 dogfood r3) leaderstats a StudWork module
			-- (modules/**) creates are the display-only pattern itself: not a risk, not a plan step
			local inModules = string.sub(s.path, 1, 8) == "modules/"
			for _, ls in if inModules then {} else scan.leaderstats do
				local values = A()
				for _, v in ls.values do
					table.insert(values, { name = v.name, class = v.class })
				end
				sortBy(values, "name")
				table.insert(report.leaderstats, { file = file, line = ls.line, values = values })
				risk(
					"leaderstats",
					"medium",
					"leaderstats created here; in StudWork they are display only",
					file,
					ls.line
				)
			end
			local globalKinds = {}
			for _, g in scan.globals do
				table.insert(report.globals, { kind = g.kind, file = file, line = g.line })
				if not globalKinds[g.kind] then
					globalKinds[g.kind] = true
					local what = if g.kind == "require(asset)"
						then "an asset require (code loaded from the website)"
						elseif g.kind == "loadstring" then "loadstring"
						else g.kind .. " state shared across scripts"
					risk("global_" .. g.kind, "medium", what, file, g.line)
				end
			end
			if #scan.waits > 0 then
				risk(
					"wait_loop",
					"medium",
					"wait() (deprecated; StudWork modules use events and task)",
					file,
					scan.waits[1].line
				)
			end
			if scan.empty then
				risk("empty_script", "low", "empty script", file, nil)
			elseif scan.lines > 1000 then
				risk(
					"large_script",
					"low",
					"very large script (" .. scan.lines .. " lines); port it in parts",
					file,
					nil
				)
			end
		end
	end

	-- cross-file risks: two files writing the same store/key
	for wk, files in writers do
		local list = {}
		for f, l in files do
			table.insert(list, { f = f, l = l })
		end
		if #list > 1 then
			table.sort(list, function(a, b)
				return a.f < b.f
			end)
			local name, _, key = string.match(wk, "^(.-)|(.-)|(.*)$")
			local names = {}
			for _, x in list do
				table.insert(names, x.f)
			end
			risk(
				"duplicate_writer",
				"critical",
				"store "
					.. name
					.. " key "
					.. key
					.. " is written by "
					.. #list
					.. " scripts: "
					.. table.concat(names, ", "),
				list[1].f,
				list[1].l
			)
		end
	end
	-- (v1.6.0 dogfood r2) DataStore2 keys combined into a master key (DataStore2.Combine(main,
	-- ...keys)) are saved inside the master, not as stores of their own: only the master entry
	-- (with `combined`) is reported, and the per-key DataStore2(...) entries are dropped
	local combinedKeys = {}
	for _, l in report.libraries do
		if l.name == "DataStore2" then
			for _, k in l.combined do
				combinedKeys[k] = true
			end
		end
	end
	if next(combinedKeys) then
		local kept = A()
		local dropped = {}
		for _, l in report.libraries do
			if l.name == "DataStore2" and #l.combined == 0 and combinedKeys[l.store] then
				dropped[l.store] = true
			else
				table.insert(kept, l)
			end
		end
		report.libraries = kept
		for name in dropped do
			local stillUsed = false
			for _, l in kept do
				stillUsed = stillUsed or l.store == name
			end
			for _, d in report.datastores do
				stillUsed = stillUsed or d.name == name
			end
			if not stillUsed then
				storeProjects[name] = nil
			end
		end
	end
	-- shared stores (several projects of one universe)
	local storeNames = {}
	for name in storeProjects do
		table.insert(storeNames, name)
	end
	table.sort(storeNames)
	for _, name in storeNames do
		local projs, anyWrite = A(), false
		for proj, e in storeProjects[name] do
			table.insert(projs, proj)
			anyWrite = anyWrite or e.writes
		end
		table.sort(projs)
		if #projs > 1 then
			table.insert(report.sharedStores, { name = name, projects = projs })
			if anyWrite then
				risk(
					"shared_store",
					"critical",
					"store "
						.. name
						.. " is used by several places of the universe ("
						.. table.concat(projs, ", ")
						.. "); migrate all of them",
					nil,
					nil
				)
			end
		end
	end
	-- unused remotes
	for _, r in report.remotes do
		sortBy(r.handlers, "file", "line", "kind")
		sortBy(r.fires, "file", "line", "kind")
		if #r.handlers == 0 and #r.fires == 0 then
			risk(
				"unused_remote",
				"low",
				"remote " .. r.name .. " has no handler and is never fired",
				r.path,
				nil
			)
		end
	end

	for _, d in report.datastores do
		d.keyPatterns = uniqSorted(d.keyPatterns)
		sortBy(d.calls, "file", "line", "op")
		d._projects = nil
	end
	sortBy(report.scripts, "path")
	sortBy(report.notExtracted, "path")
	sortBy(report.placeDuplicates, "path")
	sortBy(report.datastores, "name", "scope", "kind")
	sortBy(report.libraries, "name", "store", "file", "line")
	sortBy(report.purchases.processReceipt, "file", "line")
	sortBy(report.purchases.products, "id")
	sortBy(report.purchases.passes, "id", "file", "line")
	sortBy(report.purchases.prompts, "file", "line", "kind")
	sortBy(report.purchases.ownership, "file", "line", "kind")
	sortBy(report.remotes, "name")
	sortBy(report.leaderstats, "file", "line")
	sortBy(report.ui, "path")
	sortBy(report.globals, "file", "line", "kind")
	table.sort(risks, function(a, b)
		if a.level ~= b.level then
			return LEVEL_RANK[a.level] < LEVEL_RANK[b.level]
		end
		return a.id < b.id
	end)
	report.plan = Audit.plan(report, fileScan)
	return report
end

--------------------------------------------------------------------------------
-- the plan (§1 "The plan": fixed order, steps with nothing to do left out)
--------------------------------------------------------------------------------

local function riskLines(report, kinds: { [string]: boolean }): { string }
	local out = {}
	for _, r in report.risks do
		local kind = string.match(r.id, "^([^:]+)")
		if kinds[kind] then
			local at = if r.file ~= NULL
				then " (" .. r.file .. (if r.line ~= NULL then ":" .. r.line else "") .. ")"
				else ""
			table.insert(out, "[" .. r.level .. "] " .. r.message .. at)
		end
	end
	return out
end

function Audit.plan(report, fileScan)
	local steps = A()
	local function step(id: string, title: string, auto: boolean, files, doText: string, check: string)
		table.insert(steps, {
			n = #steps + 1,
			id = id,
			title = title,
			auto = auto,
			files = uniqSorted(files),
			["do"] = doText,
			check = check,
		})
	end

	step(
		"init",
		"Add StudWork to the project",
		true,
		{ "studwork.json", "studwork-legacy.json", "default.project.json" },
		"Run `tools/adopt --init <project> --name <gameId>` (pick a game id whose save store PlayerData_<gameId> isn't one of the old stores below). It adds the studwork/ submodule, studwork.json, the tool wrappers, the game module and studwork-legacy.json.",
		"`tools/lint` passes; studwork-legacy.json lists every old file with a reason."
	)

	-- 2/3: save map and legacy import
	local saveFiles = {}
	local sources = {}
	for _, d in report.datastores do
		for _, c in d.calls do
			table.insert(saveFiles, c.file)
		end
		if d.kind == "global" and d.name ~= "<global>" then
			for _, k in d.keyPatterns do
				if string.find(k, "{userId}", 1, true) then
					local scope = if d.scope ~= NULL then ', scope = "' .. d.scope .. '"' else ""
					table.insert(
						sources,
						'{ kind = "datastore", name = "'
							.. d.name
							.. '"'
							.. scope
							.. ', key = "'
							.. k
							.. '" }'
					)
				end
			end
		end
	end
	local combinedSet = {}
	for _, l in report.libraries do
		if l.name == "DataStore2" then
			for _, k in l.combined do
				combinedSet[k] = true
			end
		end
	end
	for _, l in report.libraries do
		table.insert(saveFiles, l.file)
		if l.name == "ProfileService" or l.name == "ProfileStore" then
			table.insert(
				sources,
				'{ kind = "'
					.. string.lower(l.name)
					.. '", name = "'
					.. l.store
					.. '", key = "'
					.. l.keyPattern
					.. '" }'
			)
		elseif #l.combined > 0 then
			local keys = {}
			for _, k in l.combined do
				table.insert(keys, '"' .. k .. '"')
			end
			table.insert(
				sources,
				'{ kind = "datastore2", name = "'
					.. l.store
					.. '", combined = { '
					.. table.concat(keys, ", ")
					.. " } }"
			)
		elseif not combinedSet[l.store] then
			table.insert(sources, '{ kind = "datastore2", name = "' .. l.store .. '" }')
		end
	end
	sources = uniqSorted(sources)
	local sold = {}
	for _, pr in report.purchases.products do
		for _, f in pr.sold do
			table.insert(sold, f)
		end
	end
	sold = uniqSorted(sold)
	if #saveFiles > 0 then
		local storeNames = {}
		for _, d in report.datastores do
			table.insert(storeNames, d.name)
		end
		for _, l in report.libraries do
			table.insert(storeNames, l.store .. " (" .. l.name .. ")")
		end
		local text = "Write the save map: one table in modules/<gameId>/README.md mapping every old save field to its new home (a kit section through the kit's txApi, or the game module's own section). Old stores: "
			.. table.concat(uniqSorted(storeNames), ", ")
			.. "."
		if #sold > 0 then
			text ..= " Fields a product sells (" .. table.concat(sold, ", ") .. ") must map to a currency listed in compliance.paidCurrencies, or to items (the import tags them paid)."
		end
		local blockers = riskLines(report, {
			key_not_derivable = true,
			duplicate_writer = true,
			store_collision = true,
			remove_player_data = true,
		})
		if #blockers > 0 then
			text ..= " Resolve first: " .. table.concat(blockers, "; ") .. "."
		end
		step(
			"save-map",
			"Map every old save field",
			false,
			saveFiles,
			text,
			"Every field the old code reads or writes has a row; every sold field maps to a paid currency or an item."
		)
		local imp =
			'Register `ctx.data.importLegacy({ id = "v1-save", version = 1, source = ..., import = function(tx, old, info) ... end })` in modules/<gameId>/server/init.luau, writing kits only through their txApi.'
		if #sources > 0 then
			imp ..= " Sources found: " .. table.concat(sources, "; ") .. "."
		end
		imp ..= " Add synthetic sample saves per old store in modules/<gameId>/tests/legacy/*.json (expect / dropped maps; no real player's data). If the old save kept purchase ids, return them from `receipts(old)`."
		step(
			"legacy-import",
			"Import the old save on join",
			false,
			saveFiles,
			imp,
			"`tools/test-migration` passes (nothing lost, import twice is safe, failures change no data)."
		)
	end

	-- 4: purchases
	local pur = report.purchases
	if #pur.processReceipt + #pur.products + #pur.passes + #pur.prompts + #pur.ownership > 0 then
		local files = {}
		for _, k in { "processReceipt", "products", "passes", "prompts", "ownership" } do
			for _, e in pur[k] do
				table.insert(files, e.file)
			end
		end
		local parts = {}
		local first = riskLines(
			report,
			{ receipt_no_history = true, product_random = true, paid_random_no_odds = true }
		)
		if #first > 0 then
			table.insert(parts, "Fix first: " .. table.concat(first, "; ") .. ".")
		end
		if #pur.products > 0 then
			local prods = {}
			for _, p in pur.products do
				local s = tostring(p.id) .. " (" .. p.file .. ":" .. p.line
				if #p.sold > 0 then
					s ..= ", sells " .. table.concat(p.sold, ", ")
				end
				if p.random then
					s ..= ", RANDOM: roll through ctx.compliance with odds shown"
				end
				table.insert(prods, s .. ")")
			end
			table.insert(
				parts,
				"Port every product to `ctx.shop.onProduct`: " .. table.concat(prods, "; ") .. "."
			)
		end
		if #pur.processReceipt > 0 then
			table.insert(
				parts,
				"Remove the old ProcessReceipt (Shop owns it). Bring the old receipt history over: ids kept in the save -> `importLegacy.receipts(old)`; a separate history DataStore -> `ctx.shop.legacyReceipts({ name = ..., key = ... })`."
			)
		end
		if #pur.passes > 0 then
			local ids = {}
			for _, p in pur.passes do
				table.insert(ids, tostring(p.id))
			end
			table.insert(
				parts,
				"Passes ("
					.. table.concat(uniqSorted(ids), ", ")
					.. "): use `ctx.shop.onPassOwned` / `ctx.shop.ownsPass`."
			)
		end
		table.insert(
			parts,
			"`ctx.shop.onLegacyProduct` may bridge an old handler during development only; none may be left at the end."
		)
		step(
			"purchases",
			"Move purchases to ctx.shop",
			false,
			files,
			table.concat(parts, " "),
			"`tools/test` passes; no ProcessReceipt or purchase code left outside StudWork; one purchase grants once."
		)
	end

	-- 5: remotes
	if #report.remotes > 0 then
		local files, lines = {}, {}
		local trustByRemote = {}
		for _, r in report.risks do
			if string.match(r.id, "^remote_trusts_client:") then
				local name, param =
					string.match(r.message, "^remote (.-): the handler writes the client%-supplied `(.-)`")
				if name then
					trustByRemote[name] = trustByRemote[name] or {}
					table.insert(trustByRemote[name], param)
				end
			end
		end
		for _, r in report.remotes do
			local hs = {}
			for _, h in r.handlers do
				table.insert(hs, h.kind .. " " .. h.file .. ":" .. h.line)
				table.insert(files, h.file)
			end
			local line = r.name .. " (" .. r.class .. "): "
			if #hs > 0 then
				line ..= table.concat(hs, ", ")
			else
				line ..= "no handler"
			end
			if trustByRemote[r.name] then
				line ..= "; validate " .. table.concat(uniqSorted(trustByRemote[r.name]), ", ") .. " on the server"
			end
			table.insert(lines, line)
		end
		step(
			"remotes",
			"Turn every remote into a module action",
			false,
			files,
			"One module action per remote (Core.Net / the module's net.blink), the server deciding every amount, price and item: "
				.. table.concat(lines, "; ")
				.. ".",
			"`tools/lint` reports no remotes finding outside studwork-legacy.json; each action has a spec."
		)
	end

	-- 6: leaderstats, UI, remaining systems
	if #report.leaderstats > 0 then
		local files, vals = {}, {}
		for _, l in report.leaderstats do
			table.insert(files, l.file)
			for _, v in l.values do
				table.insert(vals, v.name)
			end
		end
		step(
			"leaderstats",
			"Show leaderstats from module state",
			false,
			files,
			"leaderstats become display only, written from the owning module's state (never read back as the source of truth). Values: "
				.. (if #vals > 0 then table.concat(uniqSorted(vals), ", ") else "(none found)")
				.. ".",
			"The values match the save after a join and after a purchase."
		)
	end
	if #report.ui > 0 then
		local files, names = {}, {}
		for _, u in report.ui do
			table.insert(names, u.path)
			for _, s in u.scripts do
				table.insert(files, s)
			end
		end
		step(
			"ui",
			"Keep or move the UI",
			false,
			files,
			"Decide per screen: keep the old UI (it stays in the place / its folder) or move it to the UI kit. Screens: "
				.. table.concat(names, ", ")
				.. ". UI code calls module actions, never remotes.",
			"Every screen opens and its buttons reach a module action."
		)
	end
	local rest = {}
	for file, fsr in fileScan do
		local s = fsr.scan
		local busy = #s.datastores
			+ #s.libraries
			+ #s.purchases.processReceipt
			+ #s.purchases.prompts
			+ #s.remotes.handlers
			+ #s.leaderstats
		if busy == 0 and not s.empty and string.sub(fsr.script.path, 1, 6) ~= "place:" then
			table.insert(rest, file)
		end
	end
	if #rest > 0 then
		step(
			"systems",
			"Port the remaining systems",
			false,
			rest,
			"Port each remaining system to a module (`tools/make-module`), one system at a time (independent systems can go to parallel agents, each owning its files), or keep it with a reason in studwork-legacy.json.",
			"`tools/lint`, `tools/typecheck` and `tools/test` pass after each system."
		)
	end

	if #report.placeDuplicates > 0 then
		local names = {}
		for _, d in report.placeDuplicates do
			table.insert(names, d.path)
		end
		step(
			"strip-place",
			"Strip the extracted scripts from the place",
			true,
			{ "studwork.json" },
			"The place file still holds the scripts --from-place extracted ("
				.. table.concat(names, ", ")
				.. "): syncing the project into it would run the old code (old saves included) next to StudWork. Once their code is ported or listed, run `tools/adopt --strip-place . --extracted` (writes <place>.studwork.rbxlx and points studwork.json at it; the original is never modified).",
			"`tools/adopt --verify .` no longer names any extracted script."
		)
	end
	step(
		"shrink-legacy",
		"Shrink the legacy list",
		false,
		{ "studwork-legacy.json" },
		"Delete or port each file listed in studwork-legacy.json until the list is empty or every entry left is justified by its reason. No entry may still list the `purchases` check.",
		"`tools/lint` passes with no stale entry warning."
	)
	step(
		"verify",
		"Verify",
		true,
		{},
		"Run `tools/adopt --verify <project>`, `tools/lint`, `tools/typecheck`, `tools/test`, `tools/test-migration` and `tools/build`.",
		"All pass; `tools/adopt --verify` prints nothing left."
	)
	local cut =
		"Hand the user the cutover checklist (docs/framework/adopting.md §2): migrate every place of the universe that uses an imported store"
	if #report.sharedStores > 0 then
		local names = {}
		for _, s in report.sharedStores do
			table.insert(names, s.name .. " (" .. table.concat(s.projects, ", ") .. ")")
		end
		cut ..= " (shared: " .. table.concat(names, "; ") .. ")"
	end
	cut ..= ', test in a test place of the same universe with test accounts, buy one product, then publish live with "Shut down all servers". The agent stops here; the user does the cutover.'
	step(
		"cutover",
		"Cutover (the user)",
		false,
		{},
		cut,
		"The user confirms the test-place checks before publishing live."
	)
	return steps
end

--------------------------------------------------------------------------------
-- output
--------------------------------------------------------------------------------

local KEY_ORDER = {}
for i, k in
	{
		"reportVersion",
		"tool",
		"studwork",
		"projects",
		"scripts",
		"notExtracted",
		"placeDuplicates",
		"datastores",
		"libraries",
		"sharedStores",
		"purchases",
		"remotes",
		"leaderstats",
		"ui",
		"globals",
		"risks",
		"plan",
		"n",
		"id",
		"level",
		"kind",
		"name",
		"title",
		"auto",
		"root",
		"projectFile",
		"placeFile",
		"path",
		"class",
		"side",
		"lines",
		"project",
		"store",
		"scope",
		"keyPattern",
		"keyPatterns",
		"combined",
		"calls",
		"op",
		"message",
		"file",
		"line",
		"key",
		"detail",
		"historyCheck",
		"sold",
		"random",
		"processReceipt",
		"products",
		"passes",
		"prompts",
		"ownership",
		"handlers",
		"fires",
		"values",
		"children",
		"scripts",
		"findings",
		"files",
		"do",
		"check",
	}
do
	KEY_ORDER[k] = KEY_ORDER[k] or i
end

local function jsonString(s: string): string
	s = string.gsub(s, '[%c"\\]', function(c)
		local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" }
		return map[c] or string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. s .. '"'
end

local function encode(v, indent: string, out)
	if type(v) == "boolean" then
		table.insert(out, tostring(v))
	elseif type(v) == "number" then
		if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			table.insert(out, string.format("%d", v))
		else
			table.insert(out, tostring(v))
		end
	elseif type(v) == "string" then
		table.insert(out, jsonString(v))
	elseif type(v) == "table" and v ~= NULL then
		local inner = indent .. "  "
		local isArray = getmetatable(v) ~= OBJECT
			and (getmetatable(v) == ARRAY or next(v) == nil or v[1] ~= nil)
		if isArray then
			if #v == 0 then
				table.insert(out, "[]")
				return
			end
			table.insert(out, "[\n")
			for i, x in v do
				table.insert(out, inner)
				encode(x, inner, out)
				table.insert(out, if i < #v then ",\n" else "\n")
			end
			table.insert(out, indent .. "]")
		else
			local keys = {}
			for k, x in v do
				if type(k) == "string" and string.sub(k, 1, 1) ~= "_" and x ~= nil then
					table.insert(keys, k)
				end
			end
			table.sort(keys, function(a, b)
				local ra, rb = KEY_ORDER[a] or 1000, KEY_ORDER[b] or 1000
				if ra ~= rb then
					return ra < rb
				end
				return a < b
			end)
			if #keys == 0 then
				table.insert(out, "{}")
				return
			end
			table.insert(out, "{\n")
			for i, k in keys do
				table.insert(out, inner .. jsonString(k) .. ": ")
				encode(v[k], inner, out)
				table.insert(out, if i < #keys then ",\n" else "\n")
			end
			table.insert(out, indent .. "}")
		end
	else
		table.insert(out, "null")
	end
end

function Audit.encodeJson(value): string
	local out = {}
	encode(value, "", out)
	table.insert(out, "\n")
	return table.concat(out)
end

local function at(file, line): string
	if file == nil or file == NULL then
		return ""
	end
	if line == nil or line == NULL then
		return "`" .. file .. "`"
	end
	return "`" .. file .. ":" .. line .. "`"
end

local function mdCell(s: string): string
	return (string.gsub(s, "|", "\\|"))
end

function Audit.counts(report)
	local c = { critical = 0, high = 0, medium = 0, low = 0 }
	for _, r in report.risks do
		c[r.level] += 1
	end
	return c
end

function Audit.markdown(report): string
	local L = {}
	local function w(s: string?)
		table.insert(L, s or "")
	end
	local c = Audit.counts(report)
	w("# StudWork adoption report")
	w()
	w(
		"Generated by `tools/adopt --audit` (StudWork "
			.. report.studwork
			.. ", report version "
			.. report.reportVersion
			.. "). Read-only and regenerated on every run; the machine-readable twin is `studwork-adopt-report.json`. The numbered plan at the end is the order to follow."
	)
	w()
	w("## Projects")
	w()
	for _, p in report.projects do
		local extra = {}
		if p.projectFile ~= NULL then
			table.insert(extra, "project file `" .. p.projectFile .. "`")
		end
		if p.placeFile ~= NULL then
			table.insert(extra, "place file `" .. p.placeFile .. "`")
		end
		w(
			"- `"
				.. p.root
				.. "` ("
				.. p.kind
				.. (if #extra > 0 then ", " .. table.concat(extra, ", ") else "")
				.. ")"
		)
	end
	w()
	w("## Summary")
	w()
	w(
		string.format(
			"%d scripts, %d DataStores, %d save-library uses, %d products, %d passes, %d remotes, %d scripts left in the place.",
			#report.scripts,
			#report.datastores,
			#report.libraries,
			#report.purchases.products,
			#report.purchases.passes,
			#report.remotes,
			#report.notExtracted
		)
	)
	w()
	w(
		string.format(
			"Risks: **%d critical**, %d high, %d medium, %d low.",
			c.critical,
			c.high,
			c.medium,
			c.low
		)
	)
	w()
	w("## Risks")
	w()
	if #report.risks == 0 then
		w("None found.")
	else
		for _, lvl in LEVELS do
			local any = false
			for _, r in report.risks do
				if r.level == lvl then
					if not any then
						w("### " .. lvl)
						w()
						any = true
					end
					local where = at(r.file, r.line)
					w("- " .. r.message .. (if where ~= "" then " (" .. where .. ")" else ""))
				end
			end
			if any then
				w()
			end
		end
	end
	w("## DataStores")
	w()
	if #report.datastores == 0 then
		w("None found.")
	else
		w("| Store | Scope | Kind | Key patterns | Calls |")
		w("|---|---|---|---|---|")
		for _, d in report.datastores do
			local calls = {}
			for _, cl in d.calls do
				table.insert(calls, cl.op .. " " .. at(cl.file, cl.line))
			end
			w(
				"| "
					.. mdCell(d.name)
					.. " | "
					.. (if d.scope == NULL then "" else mdCell(d.scope))
					.. " | "
					.. d.kind
					.. " | "
					.. mdCell(table.concat(d.keyPatterns, ", "))
					.. " | "
					.. table.concat(calls, ", ")
					.. " |"
			)
		end
	end
	w()
	w("## Save libraries")
	w()
	if #report.libraries == 0 then
		w("None found.")
	else
		for _, l in report.libraries do
			local comb = if #l.combined > 0 then ", combined: " .. table.concat(l.combined, ", ") else ""
			w(
				"- "
					.. l.name
					.. " store `"
					.. l.store
					.. "`, key `"
					.. l.keyPattern
					.. "`"
					.. comb
					.. " ("
					.. at(l.file, l.line)
					.. ")"
			)
		end
	end
	w()
	if #report.sharedStores > 0 then
		w("## Stores shared by several places")
		w()
		for _, s in report.sharedStores do
			w("- `" .. s.name .. "`: " .. table.concat(s.projects, ", "))
		end
		w()
	end
	w("## Purchases")
	w()
	local pur = report.purchases
	if #pur.processReceipt + #pur.products + #pur.passes + #pur.prompts + #pur.ownership == 0 then
		w("None found.")
	else
		for _, r in pur.processReceipt do
			w(
				"- ProcessReceipt "
					.. at(r.file, r.line)
					.. ": history check "
					.. (if r.historyCheck then "yes" else "**no**")
			)
		end
		for _, p in pur.products do
			w(
				"- product "
					.. p.id
					.. " "
					.. at(p.file, p.line)
					.. (if #p.sold > 0 then ", sells " .. table.concat(p.sold, ", ") else "")
					.. (if p.random then ", **uses randomness**" else "")
			)
		end
		for _, p in pur.passes do
			w("- pass " .. p.id .. " " .. at(p.file, p.line))
		end
		for _, p in pur.prompts do
			w("- " .. p.kind .. (if p.id ~= NULL then " " .. p.id else "") .. " " .. at(p.file, p.line))
		end
		for _, p in pur.ownership do
			w("- " .. p.kind .. (if p.id ~= NULL then " " .. p.id else "") .. " " .. at(p.file, p.line))
		end
	end
	w()
	w("## Remotes")
	w()
	if #report.remotes == 0 then
		w("None found.")
	else
		for _, r in report.remotes do
			local hs, fs = {}, {}
			for _, h in r.handlers do
				table.insert(hs, h.kind .. " " .. at(h.file, h.line))
			end
			for _, f in r.fires do
				table.insert(fs, f.kind .. " " .. at(f.file, f.line))
			end
			w(
				"- `"
					.. r.name
					.. "` ("
					.. r.class
					.. ", "
					.. r.path
					.. "): handlers "
					.. (if #hs > 0 then table.concat(hs, ", ") else "none")
					.. "; fired "
					.. (if #fs > 0 then table.concat(fs, ", ") else "never")
			)
		end
	end
	w()
	if #report.leaderstats > 0 then
		w("## leaderstats")
		w()
		for _, l in report.leaderstats do
			local vs = {}
			for _, v in l.values do
				table.insert(vs, v.name .. " (" .. v.class .. ")")
			end
			w(
				"- "
					.. at(l.file, l.line)
					.. ": "
					.. (if #vs > 0 then table.concat(vs, ", ") else "no values found")
			)
		end
		w()
	end
	if #report.ui > 0 then
		w("## UI")
		w()
		for _, u in report.ui do
			w(
				"- `"
					.. u.path
					.. "` ("
					.. u.class
					.. (if u.children then ", " .. u.children .. " children" else "")
					.. ")"
					.. (if #u.scripts > 0 then ": " .. table.concat(u.scripts, ", ") else "")
			)
		end
		w()
	end
	if #report.globals > 0 then
		w("## Globals")
		w()
		for _, g in report.globals do
			w("- " .. g.kind .. " " .. at(g.file, g.line))
		end
		w()
	end
	if #report.placeDuplicates > 0 then
		w("## Extracted scripts still in the place")
		w()
		w(
			"The project has these scripts' code, and the place file still holds them: syncing the project into it runs both. Strip them with `tools/adopt --strip-place . --extracted`."
		)
		w()
		for _, d in report.placeDuplicates do
			w("- `" .. d.path .. "` (" .. d.class .. ")")
		end
		w()
	end
	if #report.notExtracted > 0 then
		w("## Scripts left in the place (not extracted)")
		w()
		for _, n in report.notExtracted do
			local fs = {}
			for _, f in n.findings do
				table.insert(fs, f.detail .. " (line " .. f.line .. ")")
			end
			w(
				"- `"
					.. n.path
					.. "` ("
					.. n.class
					.. ")"
					.. (if #fs > 0 then ": " .. table.concat(fs, ", ") else "")
			)
		end
		w()
	end
	w("## Scripts")
	w()
	w("| Path | Class | Side | Lines |")
	w("|---|---|---|---|")
	for _, s in report.scripts do
		w("| `" .. mdCell(s.path) .. "` | " .. s.class .. " | " .. s.side .. " | " .. s.lines .. " |")
	end
	w()
	w("## Plan")
	w()
	w("Follow top to bottom. Each step names its files, what to do, and how to check it.")
	w()
	for _, st in report.plan do
		w(
			st.n
				.. ". **"
				.. st.title
				.. "** (`"
				.. st.id
				.. "`"
				.. (if st.auto then ", automatic" else "")
				.. ")"
		)
		if #st.files > 0 then
			local fs = {}
			for _, f in st.files do
				table.insert(fs, "`" .. f .. "`")
			end
			w("   - Files: " .. table.concat(fs, ", "))
		end
		w("   - Do: " .. st["do"])
		w("   - Check: " .. st.check)
	end
	return table.concat(L, "\n") .. "\n"
end

--------------------------------------------------------------------------------
-- entry points
--------------------------------------------------------------------------------

function Audit.run(env, absPaths: { string }, opts)
	opts = opts or {}
	local projects = {}
	for _, path in absPaths do
		local p, err = Audit.loadProject(env, path)
		if p == nil then
			return nil, err
		end
		table.insert(projects, p)
	end
	if #projects == 0 then
		return nil, "no project given"
	end
	local reportDir = projects[1].root
	local report = Audit.build(env, projects, reportDir)
	if opts.write then
		env.fs.writeFile(reportDir .. "/" .. Audit.REPORT_JSON, Audit.encodeJson(report))
		env.fs.writeFile(reportDir .. "/" .. Audit.REPORT_MD, Audit.markdown(report))
	end
	return report, nil, reportDir
end

local LUAU_SKIP = {
	[".git"] = true,
	studwork = true,
	Packages = true,
	ServerPackages = true,
	DevPackages = true,
	node_modules = true,
	build = true,
	[".cache"] = true,
}

-- every project Luau file outside studwork/ (and dependency/build folders), relative to root
local function luauFiles(env, root: string): { string }
	local out = {}
	local function walk(rel: string)
		local abs = if rel == "" then root else root .. "/" .. rel
		local entries = env.fs.readDir(abs)
		table.sort(entries)
		for _, e in entries do
			local r = if rel == "" then e else rel .. "/" .. e
			local full = abs .. "/" .. e
			if env.fs.isDir(full) then
				if not LUAU_SKIP[e] and string.sub(e, 1, 1) ~= "." then
					walk(r)
				end
			elseif
				(string.match(e, "%.luau$") or string.match(e, "%.lua$"))
				and not Audit.isGenerated(env.fs, full)
			then
				table.insert(out, r)
			end
		end
	end
	walk("")
	return out
end

-- (v1.6.0 dogfood r3) every `$path` of the project file that doesn't exist (left behind after the
-- old scripts were deleted): { instance, path, projectFile }, in tree order
function Audit.stalePaths(env, root: string, projectFile: any): { any }
	local out = {}
	if type(projectFile) ~= "string" then
		return out
	end
	local project = readJson(env, root .. "/" .. projectFile)
	if type(project) ~= "table" or type(project.tree) ~= "table" then
		return out
	end
	local function walk(node, instPath: string)
		-- (an `{ "optional": ... }` $path may be missing by design)
		local p = node["$path"]
		if type(p) == "string" and string.sub(p, 1, 1) ~= "/" then
			local ok, m = pcall(env.fs.metadata, root .. "/" .. p)
			if not (ok and m.exists) then
				table.insert(out, {
					instance = if instPath == "" then "<root>" else instPath,
					path = p,
					projectFile = projectFile,
				})
			end
		end
		local keys = {}
		for k, v in node do
			if type(k) == "string" and string.sub(k, 1, 1) ~= "$" and type(v) == "table" then
				table.insert(keys, k)
			end
		end
		table.sort(keys)
		for _, k in keys do
			walk(node[k], if instPath == "" then k else instPath .. "." .. k)
		end
	end
	walk(project.tree, "")
	return out
end

-- What `tools/adopt --verify` still refuses (empty = clean), one line each.
function Audit.verifyIssues(env, absPath: string)
	local report, err, reportDir = Audit.run(env, { absPath }, { write = false })
	if report == nil then
		return nil, err
	end
	local issues = {}
	for _, r in report.risks do
		if r.level == "critical" then
			table.insert(
				issues,
				"critical: "
					.. r.message
					.. (
						if r.file ~= NULL
							then " (" .. r.file .. (if r.line ~= NULL then ":" .. r.line else "") .. ")"
							else ""
					)
			)
		end
		if r.level == "high" and string.match(r.id, "^place_missing:") then
			table.insert(issues, "place file missing: " .. r.file)
		end
	end
	local placeRel = nil
	for _, pr in report.projects do
		if pr.placeFile ~= NULL then
			placeRel = pr.placeFile
		end
	end
	for _, d in report.placeDuplicates do
		table.insert(
			issues,
			"`"
				.. d.path
				.. "` is still in "
				.. tostring(placeRel)
				.. " (old code runs next to StudWork): run tools/adopt --strip-place . --extracted"
		)
	end
	for _, n in report.notExtracted do
		if unsafeFindings(n.findings) then
			table.insert(
				issues,
				"left in the place: " .. n.path .. " uses DataStores, ProcessReceipt or product prompts"
			)
		end
	end
	if not Audit.isPlaceFile(absPath) then
		for _, stale in
			Audit.stalePaths(env, reportDir, report.projects[1] and report.projects[1].projectFile)
		do
			table.insert(
				issues,
				"stale $path: "
					.. stale.instance
					.. " -> "
					.. stale.path
					.. " doesn't exist; remove the entry from "
					.. stale.projectFile
					.. " (Rojo builds anyway, so nothing else catches it)"
			)
		end
		for _, rel in luauFiles(env, reportDir) do
			local ok, src = pcall(env.fs.readFile, reportDir .. "/" .. rel)
			if ok then
				for _, hit in env.Scan.scan(src).onLegacyProduct do
					table.insert(
						issues,
						"onLegacyProduct left: "
							.. rel
							.. ":"
							.. hit.line
							.. " (development bridge only; port it to ctx.shop.onProduct)"
					)
				end
			end
		end
		local legacyPath = reportDir .. "/" .. Audit.LEGACY_LIST
		if env.fs.isFile(legacyPath) then
			local list = readJson(env, legacyPath)
			if type(list) ~= "table" or type(list.files) ~= "table" then
				table.insert(issues, Audit.LEGACY_LIST .. ": not readable as { files = [...] }")
			else
				for _, entry in list.files do
					if
						type(entry) == "table"
						and type(entry.checks) == "table"
						and table.find(entry.checks, "purchases")
					then
						table.insert(
							issues,
							Audit.LEGACY_LIST
								.. ": "
								.. tostring(entry.path)
								.. " still lists the purchases check (old save or purchase code still runs)"
						)
					end
				end
			end
		end
	end
	return issues
end

return Audit
