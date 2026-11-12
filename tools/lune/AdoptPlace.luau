--!nocheck
--[[
	tools/lune/AdoptPlace.luau (StudWork v1.6.0, docs/framework/adopting.md §1): tools/adopt
	--from-place <file> [--out <dir>]. A Studio-only game's CODE CONTAINERS -> a Rojo project; the
	map, models and UI stay in the place.

	Zero requires: env = { fs, serde, roblox, process, Scan, Audit, version }.

	  Place.sanitize(name) -> fileName, changed     an untrusted instance name -> a safe file name
	  Place.plan(env, place) -> { files, dirs, collisions, containers }   pure, nothing written
	  Place.run(env, placeAbs, outAbs) -> result?, err?   checks everything, then writes
	  Place.find(root, path) -> ({ Instance }, err?)   the instances at a full dotted path
	                                    ("StarterGui.ShopGui.ShopGuiClient", the audit report's
	                                    notExtracted[].path); names with dots are matched too
	  Place.strip(env, projectAbs, paths) -> result?, err?   tools/adopt --strip-place (v1.6.0
	                                    dogfood r2): studwork.json's placeFile without the named
	                                    instances -> <name>.studwork.rbxlx (or .rbxl) next to it,
	                                    studwork.json pointed at the copy. The original is never
	                                    written; on the copy it removes more (repeatable). Every
	                                    path must exist (exactly one instance), or nothing is written.

	Safety rules (all checked BEFORE the first write; any failure writes nothing):
	  - names are sanitized (separators, `.`/`..`, control and Windows/macOS-invalid characters,
	    reserved names, Rojo's special suffixes); the real name goes into a .meta.json
	  - collisions are case-insensitive (macOS) and get a `~2` suffix; each one is reported
	  - every renamed instance is listed (output and the manifest's `renamed`): Rojo 7.7 ignores a
	    meta `Name` property (it warns), so the instance syncs under the file name and code that
	    finds it by its old name must be updated
	  - every target resolves (after symlinks, `realpath`) inside --out
	  - a fresh --out may hold other files (v1.6.0 dogfood: a game's saves/, notes); any file at a
	    path the run writes is refused unless an earlier run's manifest knows it unchanged (the old audit
	    reports are allowed); a later run overwrites only files listed in .studwork-from-place.json
	    with an unchanged hash, any other existing file stops the run
	The place file is never modified. The audit report of the extracted project is written last.
]]

local Place = {}

Place.CONTAINER_DIRS = {
	"src/ServerScriptService",
	"src/ServerStorage",
	"src/ReplicatedStorage",
	"src/ReplicatedFirst",
	"src/StarterPlayer/StarterPlayerScripts",
	"src/StarterPlayer/StarterCharacterScripts",
}

local RESERVED = { CON = true, PRN = true, AUX = true, NUL = true }
for i = 1, 9 do
	RESERVED["COM" .. i] = true
	RESERVED["LPT" .. i] = true
end
-- suffixes Rojo gives a meaning to (a ModuleScript named "x.server" would become a Script)
local SPECIAL_SUFFIXES = {
	"server",
	"client",
	"meta",
	"model",
	"project",
	"json",
	"luau",
	"lua",
	"txt",
	"csv",
	"rbxm",
	"rbxmx",
	"toml",
}

-- An untrusted instance name -> a safe file/folder stem. Returns (stem, changed).
function Place.sanitize(name: string): (string, boolean)
	local s = string.gsub(name, '[%c/\\:%*%?"<>|]', "_")
	if string.match(s, "^%.*$") then
		s = string.gsub(s, "%.", "_")
		if s == "" then
			s = "_"
		end
	end
	s = string.gsub(s, "^%s+", "_")
	s = string.gsub(s, "[%s%.]+$", function(t)
		return string.rep("_", #t)
	end)
	local base = string.upper(string.match(s, "^([^%.]*)") or s)
	if RESERVED[base] then
		s = "_" .. s
	end
	local low = string.lower(s)
	if low == "init" then
		s = "_" .. s
	end
	local last = string.match(low, "%.([%w]+)$")
	if last and table.find(SPECIAL_SUFFIXES, last) then
		s = string.gsub(s, "%.", "_")
	end
	if #s > 100 then
		s = string.sub(s, 1, 100)
	end
	return s, s ~= name
end

local SUFFIX = { Script = ".server.luau", LocalScript = ".client.luau", ModuleScript = ".luau" }

local function enumName(v): string?
	if v == nil then
		return nil
	end
	local ok, n = pcall(function()
		return v.Name
	end)
	return if ok then n else nil
end

local function jsonText(env, value): string
	return env.Audit.encodeJson(value)
end

-- does this instance (a Folder or a script) hold a script anywhere through Folders/scripts?
local SCRIPT = { Script = true, LocalScript = true, ModuleScript = true }
local function holdsScripts(inst): boolean
	for _, c in inst:GetChildren() do
		if SCRIPT[c.ClassName] then
			return true
		end
		if c.ClassName == "Folder" and holdsScripts(c) then
			return true
		end
	end
	return false
end

function Place.plan(env, place)
	local Audit = env.Audit
	local files = {} -- { path, content, kind }
	local collisions = {}
	local renamed = {}
	local containers = {}

	local function meta(props, ignoreUnknown: boolean): string?
		local m = {}
		if next(props) ~= nil then
			m.properties = props
		end
		if ignoreUnknown then
			m.ignoreUnknownInstances = true
		end
		if next(m) == nil then
			return nil
		end
		return jsonText(env, m)
	end

	local function walkChildren(inst, dir: string)
		local used = {}
		local children = inst:GetChildren()
		-- stable order: by name, then class
		table.sort(children, function(a, b)
			if a.Name ~= b.Name then
				return a.Name < b.Name
			end
			return a.ClassName < b.ClassName
		end)
		for _, c in children do
			local cls = c.ClassName
			local isScript = Audit.SCRIPT_CLASSES[cls] ~= nil
			if not isScript and not (cls == "Folder" and holdsScripts(c)) then
				continue
			end
			local stem, changed = Place.sanitize(c.Name)
			local key = string.lower(stem)
			if used[key] then
				local n = 2
				while used[string.lower(stem .. "~" .. n)] do
					n += 1
				end
				stem = stem .. "~" .. n
				key = string.lower(stem)
				changed = true
				table.insert(collisions, { path = dir .. "/" .. stem, name = c.Name })
			end
			used[key] = true
			local props = {}
			if changed then
				props.Name = c.Name
				table.insert(renamed, { path = dir .. "/" .. stem, name = c.Name })
			end
			local unknownKids = false
			for _, k in c:GetChildren() do
				if
					not Audit.SCRIPT_CLASSES[k.ClassName]
					and not (k.ClassName == "Folder" and holdsScripts(k))
				then
					unknownKids = true
				end
			end
			if isScript then
				if cls == "Script" then
					local ok, rc = pcall(function()
						return c.RunContext
					end)
					local name = ok and enumName(rc)
					if name and name ~= "Legacy" then
						props.RunContext = name
					end
				end
				local okD, disabled = pcall(function()
					return c.Disabled
				end)
				if okD and disabled == true then
					props.Disabled = true
				end
				local okS, source = pcall(function()
					return c.Source
				end)
				source = if okS and type(source) == "string" then source else ""
				local asFolder = holdsScripts(c)
				if asFolder then
					local d = dir .. "/" .. stem
					table.insert(files, { path = d .. "/init" .. SUFFIX[cls], content = source })
					local mt = meta(props, unknownKids)
					if mt then
						table.insert(files, { path = d .. "/init.meta.json", content = mt })
					end
					walkChildren(c, d)
				else
					table.insert(files, { path = dir .. "/" .. stem .. SUFFIX[cls], content = source })
					local mt = meta(props, unknownKids)
					if mt then
						table.insert(files, { path = dir .. "/" .. stem .. ".meta.json", content = mt })
					end
				end
			else
				local d = dir .. "/" .. stem
				local mt = meta(props, unknownKids)
				if mt then
					table.insert(files, { path = d .. "/init.meta.json", content = mt })
				end
				walkChildren(c, d)
			end
		end
	end

	for idx, c in Audit.CONTAINERS do
		local inst = place
		for _, name in c do
			inst = inst and inst:FindFirstChild(name)
		end
		if inst and holdsScripts(inst) then
			local dir = Place.CONTAINER_DIRS[idx]
			table.insert(containers, { names = c, dir = dir })
			walkChildren(inst, dir)
		end
	end

	-- the project file: ONLY the code containers (StudWork's own entries are --init's job)
	local tree = { ["$className"] = "DataModel" }
	for _, c in containers do
		local node = { ["$path"] = c.dir, ["$ignoreUnknownInstances"] = true }
		if #c.names == 1 then
			tree[c.names[1]] = node
		else
			tree[c.names[1]] = tree[c.names[1]]
				or { ["$className"] = c.names[1], ["$ignoreUnknownInstances"] = true }
			tree[c.names[1]][c.names[2]] = node
		end
	end
	return { files = files, collisions = collisions, renamed = renamed, containers = containers, tree = tree }
end

local function realpaths(env, paths: { string }): ({ [string]: string }?, string?)
	if #paths == 0 then
		return {}
	end
	local res = env.process.exec("realpath", paths)
	if not res.ok then
		return nil, "realpath failed: " .. (res.stderr or "")
	end
	local out = {}
	local lines = string.split(string.gsub(res.stdout, "\n$", ""), "\n")
	for i, p in paths do
		out[p] = lines[i]
	end
	return out
end

-- the deepest existing ancestor of an absolute path (the path itself when it exists)
local function existingAncestor(env, abs: string): string
	local cur = abs
	while cur ~= "/" and cur ~= "" do
		local ok, m = pcall(env.fs.metadata, cur)
		if ok and m.exists then
			return cur
		end
		cur = env.Audit.dirname(cur)
		if cur == "" then
			cur = "/"
		end
	end
	return "/"
end

local function inside(root: string, path: string): boolean
	return path == root or string.sub(path, 1, #root + 1) == root .. "/"
end

local ALLOWED_IN_FRESH = { ["studwork-adopt-report.json"] = true, ["studwork-adopt-report.md"] = true }

function Place.run(env, placeAbs: string, outAbs: string)
	local fs, Audit = env.fs, env.Audit
	placeAbs = Audit.normalize(placeAbs)
	outAbs = Audit.normalize(outAbs)
	if not Audit.isPlaceFile(placeAbs) or not fs.isFile(placeAbs) then
		return nil, "not a place file (.rbxl / .rbxlx): " .. Audit.basename(placeAbs)
	end
	local place, perr = Audit.readPlace(env, placeAbs)
	if place == nil then
		return nil, perr
	end
	local plan = Place.plan(env, place)
	if #plan.containers == 0 then
		return nil,
			"the place has no scripts in a code container (ServerScriptService, ReplicatedStorage, ...)"
	end
	local placeName = Audit.basename(placeAbs)
	local projName = Place.sanitize(string.match(placeName, "^(.*)%.[^%.]+$") or placeName)
	table.insert(plan.files, {
		path = "default.project.json",
		content = Audit.encodeJson({ name = projName, tree = plan.tree }),
	})
	table.sort(plan.files, function(a, b)
		return a.path < b.path
	end)
	for _, f in plan.files do
		f.hash = env.serde.hash("sha256", f.content)
		for seg in string.gmatch(f.path, "[^/]+") do
			assert(seg ~= "." and seg ~= "..", "from-place: unsafe path segment in " .. f.path)
		end
	end

	-- 1. containment: --out and every target, after resolving symlinks
	local outExisting = existingAncestor(env, outAbs)
	local rp, rerr = realpaths(env, { outExisting })
	if rp == nil then
		return nil, rerr
	end
	local outReal = Audit.normalize(rp[outExisting] .. string.sub(outAbs, #outExisting + 1))
	local ancestors, seen = {}, {}
	for _, f in plan.files do
		local a = existingAncestor(env, outAbs .. "/" .. f.path)
		if not seen[a] then
			seen[a] = true
			table.insert(ancestors, a)
		end
	end
	local reals, err2 = realpaths(env, ancestors)
	if reals == nil then
		return nil, err2
	end
	for _, f in plan.files do
		local target = outAbs .. "/" .. f.path
		local a = existingAncestor(env, target)
		local real = Audit.normalize(reals[a] .. string.sub(target, #a + 1))
		if not inside(outReal, real) then
			return nil,
				"refusing to write "
					.. f.path
					.. ": it resolves outside --out (a symlink?); nothing was written"
		end
		local ok, m = pcall(fs.metadata, target)
		if ok and m.exists and m.kind ~= "file" then
			return nil,
				"refusing to write "
					.. f.path
					.. ": a "
					.. tostring(m.kind)
					.. " is in the way; nothing was written"
		end
	end

	-- 2. no silent overwrite
	local manifestPath = outAbs .. "/" .. Audit.MANIFEST
	local old = nil
	if fs.isFile(manifestPath) then
		local ok, v = pcall(function()
			return env.serde.decode("json", fs.readFile(manifestPath))
		end)
		if not ok or type(v) ~= "table" or type(v.files) ~= "table" then
			return nil, Audit.MANIFEST .. " is not readable; nothing was written"
		end
		old = v
	elseif fs.isDir(outAbs) then
		-- (v1.6.0 dogfood) a fresh --out may hold anything the run doesn't write (the game's own
		-- notes, saves/ ...): only an existing file at a path the plan writes stops it (below;
		-- without a manifest every such file is refused) or something in the way of a folder (1.)
		local _ = ALLOWED_IN_FRESH
	elseif fs.isFile(outAbs) then
		return nil, "--out is a file; nothing was written"
	end
	for _, f in plan.files do
		local target = outAbs .. "/" .. f.path
		if fs.isFile(target) then
			local known = old and old.files[f.path]
			local current = env.serde.hash("sha256", fs.readFile(target))
			if known == nil or known ~= current then
				return nil,
					f.path
						.. " exists and isn't an unchanged file of an earlier --from-place run; move it away first; nothing was written"
			end
		end
	end

	-- 3. write
	local manifest = {
		tool = "studwork-adopt --from-place",
		placeFile = Audit.relative(outAbs, placeAbs),
		files = Audit.object(),
		renamed = Audit.object(),
		-- (v1.6.0 dogfood r3) the instances extracted, for --strip-place --extracted and --verify
		extracted = Audit.extractedPaths(place),
	}
	for _, r in plan.renamed do
		manifest.renamed[r.path] = r.name
	end
	for _, f in plan.files do
		local target = outAbs .. "/" .. f.path
		fs.writeDir(Audit.dirname(target))
		fs.writeFile(target, f.content)
		manifest.files[f.path] = f.hash
	end
	fs.writeFile(manifestPath, Audit.encodeJson(manifest))
	local stale = {}
	if old then
		for path in old.files do
			if manifest.files[path] == nil then
				table.insert(stale, path)
			end
		end
		table.sort(stale)
	end

	-- 4. the audit of the extracted project (with the scripts left in the place)
	local report, aerr = Audit.run(env, { outAbs }, { write = true })
	if report == nil then
		return nil, "extracted, but the audit failed: " .. tostring(aerr)
	end
	return {
		files = plan.files,
		collisions = plan.collisions,
		renamed = plan.renamed,
		stale = stale,
		report = report,
		out = outAbs,
	}
end

--------------------------------------------------------------------------------
-- tools/adopt --strip-place (v1.6.0 dogfood r2)
--------------------------------------------------------------------------------

-- every instance under `root` whose full dotted path is `path` (an instance name may hold dots)
function Place.find(root, path: string): { any }
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

local function readMarker(env, projectAbs: string): (any?, string?)
	local markerPath = projectAbs .. "/studwork.json"
	if not env.fs.isFile(markerPath) then
		return nil, "no studwork.json in the project (run tools/adopt --init first)"
	end
	local text = env.fs.readFile(markerPath)
	local ok, marker = pcall(env.serde.decode, "json", text)
	if not ok or type(marker) ~= "table" then
		return nil, "studwork.json is not valid JSON"
	end
	if type(marker.placeFile) ~= "string" then
		return nil, 'studwork.json has no "placeFile" (a Rojo-only game has no place scripts to strip)'
	end
	local rel = marker.placeFile
	if
		string.sub(rel, 1, 1) == "/"
		or string.find(rel, "..", 1, true)
		or not string.match(rel, "%.rbxlx?$")
	then
		return nil,
			"studwork.json placeFile must be a project-relative .rbxl / .rbxlx path (got " .. rel .. ")"
	end
	return { text = text, rel = rel }, nil
end

-- (v1.6.0 dogfood r3) the instance paths --from-place recorded in the project's manifest
function Place.recordedExtracted(env, projectAbs: string): ({ string }?, string?)
	local manifestPath = projectAbs .. "/" .. env.Audit.MANIFEST
	if not env.fs.isFile(manifestPath) then
		return nil,
			"no " .. env.Audit.MANIFEST .. " in the project (it was not made by tools/adopt --from-place)"
	end
	local ok, m = pcall(env.serde.decode, "json", env.fs.readFile(manifestPath))
	if not ok or type(m) ~= "table" then
		return nil, env.Audit.MANIFEST .. " is not valid JSON"
	end
	if type(m.extracted) ~= "table" then
		return nil,
			env.Audit.MANIFEST
				.. ' has no "extracted" list (made by an older tools/adopt): rerun tools/adopt --from-place <place> --out . to record it, or name the instance paths'
	end
	local out = {}
	for _, p in m.extracted do
		if type(p) == "string" then
			table.insert(out, p)
		end
	end
	return out, nil
end

-- opts.extracted (v1.6.0 dogfood r3): also strip every instance the manifest's `extracted` lists
-- that the place still holds (already-stripped ones are skipped; one recorded path matching
-- several instances strips them all: --from-place extracted each)
function Place.strip(env, projectAbs: string, paths: { string }, opts: any?)
	local fs = env.fs
	local withExtracted = type(opts) == "table" and opts.extracted == true
	if #paths == 0 and not withExtracted then
		return nil, "name at least one instance path (e.g. StarterGui.ShopGui.ShopGuiClient)"
	end
	local marker, err = readMarker(env, projectAbs)
	if marker == nil then
		return nil, err
	end
	local recorded = {}
	if withExtracted then
		local rec, rerr = Place.recordedExtracted(env, projectAbs)
		if rec == nil then
			return nil, tostring(rerr) .. ". Nothing was written."
		end
		recorded = rec
	end
	local sourceRel = marker.rel
	local sourceAbs = projectAbs .. "/" .. sourceRel
	if not fs.isFile(sourceAbs) then
		return nil, "the place file " .. sourceRel .. " (studwork.json placeFile) is missing"
	end
	local stem, ext = string.match(sourceRel, "^(.*)%.(rbxlx?)$")
	local isCopy = string.match(stem, "%.studwork$") ~= nil
	local outRel = if isCopy then sourceRel else stem .. ".studwork." .. ext
	local outAbs = projectAbs .. "/" .. outRel
	if not isCopy and fs.isFile(outAbs) then
		return nil,
			outRel
				.. " already exists but studwork.json points at "
				.. sourceRel
				.. ": point placeFile at the copy (to remove more from it) or move the copy away. Nothing was written."
	end
	local ok, place = pcall(function()
		return env.roblox.deserializePlace(fs.readFile(sourceAbs))
	end)
	if not ok then
		return nil, "can't read the place file " .. sourceRel .. ": " .. tostring(place)
	end
	-- resolve every path first: one missing or ambiguous path writes nothing
	local targets, problems = {}, {}
	for _, p in paths do
		local found = Place.find(place, p)
		if #found == 0 then
			table.insert(problems, p .. ": no such instance in " .. sourceRel)
		elseif #found > 1 then
			table.insert(
				problems,
				p .. ": " .. #found .. " instances have this path; rename one in Studio first"
			)
		else
			table.insert(targets, { path = p, inst = found[1] })
		end
	end
	if #problems > 0 then
		return nil, table.concat(problems, "\n") .. "\nNothing was written."
	end
	local named = {}
	for _, p in paths do
		named[p] = true
	end
	local seenRec = {}
	for _, p in recorded do
		if not named[p] and not seenRec[p] then
			seenRec[p] = true
			for _, inst in Place.find(place, p) do
				table.insert(targets, { path = p, inst = inst })
			end
		end
	end
	if #targets == 0 then
		-- only --extracted gets here (a named path is either found or refused above): a no-op rerun
		return { source = sourceRel, out = sourceRel, removed = {}, markerChanged = false, nothing = true }
	end
	local removed = {}
	for _, t in targets do
		-- a path inside another named path goes with it
		local covered = false
		for _, other in targets do
			if other ~= t and t.inst:IsDescendantOf(other.inst) then
				covered = true
			end
		end
		table.insert(removed, { path = t.path, class = t.inst.ClassName, covered = covered })
	end
	for _, t in targets do
		if t.inst.Parent ~= nil then
			t.inst:Destroy()
		end
	end
	local bytes = env.roblox.serializePlace(place, ext == "rbxlx")
	local newText = marker.text
	if not isCopy then
		local count
		newText, count = string.gsub(marker.text, '("placeFile"%s*:%s*)"[^"]*"', function(prefix)
			return prefix .. '"' .. outRel .. '"'
		end)
		if count ~= 1 then
			return nil, "could not update placeFile in studwork.json. Nothing was written."
		end
	end
	fs.writeFile(outAbs, bytes)
	if newText ~= marker.text then
		fs.writeFile(projectAbs .. "/studwork.json", newText)
	end
	return {
		source = sourceRel,
		out = outRel,
		removed = removed,
		markerChanged = newText ~= marker.text,
	}
end

return Place
