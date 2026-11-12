--!nocheck
--[[
	tools/lune/AdoptInit (StudWork v1.6.0, docs/framework/adopting.md §2): pure helpers of
	`tools/adopt --init` (tools/_adopt-init + tools/lune/adopt-init.luau). Specs: AdoptInit.spec.luau.
	The order-keeping JSON reader/writer is tools/sync-projects' (SyncProjects), passed in where
	needed so this file stays loadable by path from the specs.

	parseArgs(args, validName) -> (opts?, error?)
	    tools/adopt --init <project> [--name <gameId>] [--modules A,B] [--tag vX.Y.Z] [--url <u>]
	                       [--dry-run] [--no-install]
	    opts = { path, name (default: the folder name), modules: { string }?, url, tag: string?,
	    dryRun: boolean, install: boolean }
	findProjectFile(entries) -> (file?, error?)
	    default.project.json, else the only *.project.json; several without a default: an error
	isSafeRel(rel) -> boolean            a relative path that stays inside the project (lexically)
	REQUIRED(gameId) -> { { service, name, node } }   the entries StudWork adds to the tree
	isOurs(node, gameId) -> boolean      an existing entry that StudWork wrote (every $path is under
	                                     studwork/, modules/<gameId>/, studwork-boot/ or is src/shared/Config): kept, never a clash
	mergeProject(SP, text, gameId) -> (newText?, added { string }, clashes { string })
	    adds the StudWork entries after the existing keys (existing keys keep their order and
	    values), the game module's server part under ServerScriptService.Modules, and the missing
	    globIgnorePaths patterns; a clash (a name StudWork needs, taken by something else) returns
	    nil and lists every clash. Re-merging the result changes nothing.
	parseFindings(text) -> { { path, line, check, message } }   guardrails output lines
	    (`<path>:<line>: [<check>] <message>`), "./" stripped
	mustFix(finding) -> boolean          never downgraded by the legacy list (adopting.md §5): the
	                                     ProcessReceipt assignment, `special`, `packages`
	legacyList(findings, report?, oldSources?) -> (list, baseline, mustFixFiles, mustFixChecks { [path]: { check } })
	    (r3) every path in oldSources (the old game's Luau files) also lists "style"; a style-only
	    file gets the baseline entry {} and AdoptInit.STYLE_REASON
	    list = { files = { { path, checks, reason } } } sorted by path; baseline = { files = {
	    [path] = { [check] = count } } }; reasons from the audit report when it explains the file
	storeCollision(report, gameId) -> string?   an old store named PlayerData_<gameId>(_Studio)
	renderStudworkJson(SP, placeFile?, baseline?) -> text
	renderLegacyJson(SP, list) -> text
	mergeGitignore(existing?, template) -> text?   the template's missing lines appended; nil when
	                                     nothing is missing
	dependsOnLines(modules) -> string    the game module's dependsOn require lines
	mustFixMessage(path, gameId, checks?) -> string   the exact next step for a never-downgraded file
	reportProducts(report?) -> (productIds, passIds)  the audit's ids, sorted and unique
	renderConfig(template, render, gameId, modules, report?) -> (text?, error?)
	    the minimal GameConfig of an adopted game without src/shared/Config (no sandbox content)
	lineDiff(old, new) -> string         a minimal unified-style diff (for --dry-run)
]]

local AdoptInit = {}

AdoptInit.DEFAULT_URL = "https://github.com/RandyjCrowley/studwork.git"
AdoptInit.USAGE = "usage: tools/adopt --init <project> [--name <gameId>] [--modules A,B] [--tag vX.Y.Z]"
	.. " [--url <studwork-url>] [--dry-run] [--no-install]"
AdoptInit.CORE = "studwork"
AdoptInit.GLOB_IGNORE = { "**/*.spec.luau", "**/README.md", "**/SOURCE.md", "**/*.blink", "**/LICENSE" }

local function baseName(path: string): string
	local trimmed = string.gsub(path, "/+$", "")
	return string.match(trimmed, "([^/]+)$") or trimmed
end
AdoptInit.baseName = baseName

local VALUE_OPTIONS = { ["--name"] = "name", ["--modules"] = "modules", ["--url"] = "url", ["--tag"] = "tag" }

function AdoptInit.parseArgs(args: { string }, validName: (string) -> boolean): (any?, string?)
	local values = {}
	local path = nil
	local dryRun, install = false, true
	local i = 1
	while i <= #args do
		local a = args[i]
		local key, inline = string.match(a, "^(%-%-[%w%-]+)=(.*)$")
		local option = key or a
		if option == "--dry-run" and key == nil then
			dryRun = true
		elseif option == "--no-install" and key == nil then
			install = false
		elseif VALUE_OPTIONS[option] then
			local value = inline
			if value == nil then
				value = args[i + 1]
				i += 1
			end
			if value == nil or value == "" or string.sub(value, 1, 2) == "--" then
				return nil, option .. " needs a value\n" .. AdoptInit.USAGE
			end
			if values[VALUE_OPTIONS[option]] ~= nil then
				return nil, option .. " given twice"
			end
			values[VALUE_OPTIONS[option]] = value
		elseif string.sub(a, 1, 2) == "--" then
			return nil, "unknown option " .. a .. "\n" .. AdoptInit.USAGE
		elseif path == nil then
			path = a
		else
			return nil, "unexpected argument " .. a .. "\n" .. AdoptInit.USAGE
		end
		i += 1
	end
	if path == nil or path == "" then
		return nil, AdoptInit.USAGE
	end
	local name = values.name or baseName(path)
	if not validName(name) then
		return nil,
			"bad game id '"
				.. name
				.. "': lowercase letters, digits, dashes; 2-32 chars, starts with a letter"
				.. (if values.name then "" else " (it defaults to the folder name; pass --name <gameId>)")
	end
	local modules = nil
	if values.modules then
		modules = {}
		for part in string.gmatch(values.modules, "[^,]+") do
			local trimmed = string.match(part, "^%s*(.-)%s*$")
			if trimmed ~= "" then
				table.insert(modules, trimmed)
			end
		end
	end
	if values.tag and not string.match(values.tag, "^v%d+%.%d+%.%d+$") then
		return nil, "--tag must be a release tag vX.Y.Z (got " .. values.tag .. ")"
	end
	return {
		path = path,
		name = name,
		modules = modules,
		url = values.url or AdoptInit.DEFAULT_URL,
		tag = values.tag,
		dryRun = dryRun,
		install = install,
	},
		nil
end

function AdoptInit.findProjectFile(entries: { string }): (string?, string?)
	local found = {}
	for _, e in entries do
		if e == "default.project.json" then
			return e, nil
		end
		if string.match(e, "%.project%.json$") then
			table.insert(found, e)
		end
	end
	table.sort(found)
	if #found == 1 then
		return found[1], nil
	elseif #found == 0 then
		return nil,
			"no *.project.json at the project root (a Studio-only game: run tools/adopt --from-place first)"
	end
	return nil,
		"several project files and no default.project.json ("
			.. table.concat(found, ", ")
			.. "): rename the one that builds the game to default.project.json"
end

function AdoptInit.isSafeRel(rel: string): boolean
	if rel == "" or string.sub(rel, 1, 1) == "/" or string.find(rel, "\\", 1, true) then
		return false
	end
	for part in string.gmatch(rel, "[^/]+") do
		if part == ".." or part == "." then
			return false
		end
	end
	return not string.find(rel, "//", 1, true)
end

-- the tree entries StudWork needs ({ service, name, node builder })
function AdoptInit.REQUIRED(SP, gameId: string, moduleName: string): { any }
	local function path(p: string): any
		local n = SP.newObject()
		SP.set(n, "$path", p)
		return n
	end
	local function folder(children: { { any } }?): any
		local n = SP.newObject()
		SP.set(n, "$className", "Folder")
		for _, c in children or {} do
			SP.set(n, c[1], c[2])
		end
		return n
	end
	local core = AdoptInit.CORE
	return {
		{ "ReplicatedStorage", "Packages", path(core .. "/deps/Packages") },
		{ "ReplicatedStorage", "FrameworkClient", path(core .. "/packages/framework/client") },
		{ "ReplicatedStorage", "Framework", path(core .. "/packages/framework/shared") },
		{ "ReplicatedStorage", "UI", path(core .. "/packages/ui") },
		{
			"ReplicatedStorage",
			"GameModule",
			folder({
				{ "module", path("modules/" .. gameId .. "/module.luau") },
				-- (v1.6.0 dogfood r2) the game module's client part: the kept old UI goes here
				{ "client", path("modules/" .. gameId .. "/client") },
			}),
		},
		{ "ReplicatedStorage", "Modules", folder() },
		{ "ServerScriptService", "Framework", path(core .. "/packages/framework/server") },
		{
			"ServerScriptService",
			"Modules",
			folder({ { moduleName, path("modules/" .. gameId .. "/server") } }),
		},
		-- (v1.6.0 dogfood: every migration needed these) GameConfig and the two boot scripts
		{ "ReplicatedStorage", "Game", folder({ { "Config", path("src/shared/Config") } }) },
		{ "ServerScriptService", "StudWorkBoot", path("studwork-boot/server") },
		{ "ReplicatedFirst", "StudWorkBoot", path("studwork-boot/client") },
		{ "ServerStorage", "ServerPackages", path(core .. "/deps/ServerPackages") },
		{ "ServerStorage", "Vendor", path(core .. "/packages/vendor") },
	}
end

function AdoptInit.isOurs(node: any, gameId: string): boolean
	if type(node) ~= "table" or not node.__object then
		return false
	end
	local ok = true
	local function walk(n: any)
		for _, key in n.keys do
			local v = n.vals[key]
			if key == "$path" then
				if
					type(v) ~= "string"
					or not (
						string.sub(v, 1, #AdoptInit.CORE + 1) == AdoptInit.CORE .. "/"
						or string.sub(v, 1, #gameId + 9) == "modules/" .. gameId .. "/"
						or string.sub(v, 1, 14) == "studwork-boot/"
						or v == "src/shared/Config"
					)
				then
					ok = false
				end
			elseif key == "$className" then
				if v ~= "Folder" then
					ok = false
				end
			elseif string.sub(key, 1, 1) ~= "$" and type(v) == "table" and v.__object then
				walk(v)
			else
				ok = false -- $properties, $ignoreUnknownInstances...: not something StudWork writes
			end
		end
	end
	walk(node)
	return ok
end

function AdoptInit.moduleName(gameId: string): string
	local out = {}
	for part in string.gmatch(gameId, "[^%-]+") do
		table.insert(out, string.upper(string.sub(part, 1, 1)) .. string.sub(part, 2))
	end
	return table.concat(out)
end

-- pathHas(path, name) -> boolean (optional): does the folder a "$path" maps hold an entry that
-- syncs as `name`? A service mapped with "$path" can still get StudWork's children (Rojo merges
-- explicit children with the folder's), unless that folder already has a child of the same name.
function AdoptInit.mergeProject(
	SP,
	text: string,
	gameId: string,
	pathHas: ((path: string, name: string) -> boolean)?
): (string?, { string }, { string })
	local project = SP.decode(text)
	local added, clashes = {}, {}
	if type(project) ~= "table" or not project.__object then
		return nil, added, { "the project file is not a JSON object" }
	end
	local tree = project.vals.tree
	if type(tree) ~= "table" or not tree.__object then
		return nil, added, { 'the project file has no "tree" object' }
	end
	local moduleName = AdoptInit.moduleName(gameId)
	local badService = {}
	for _, req in AdoptInit.REQUIRED(SP, gameId, moduleName) do
		local serviceName, name, node = req[1], req[2], req[3]
		local service = tree.vals[serviceName]
		if badService[serviceName] then
			continue
		elseif service == nil then
			service = SP.newObject()
			SP.set(tree, serviceName, service)
			table.insert(added, serviceName)
		elseif type(service) ~= "table" or not service.__object then
			table.insert(clashes, serviceName .. " (not an object)")
			badService[serviceName] = true
			continue
		elseif service.vals["$path"] ~= nil then
			local mapped = service.vals["$path"]
			if pathHas == nil or type(mapped) ~= "string" then
				table.insert(
					clashes,
					serviceName .. ' (mapped with "$path"; StudWork needs to add children to it)'
				)
				badService[serviceName] = true
				continue
			end
			if service.vals[name] == nil and pathHas(mapped, name) then
				table.insert(
					clashes,
					`{serviceName}.{name} (the folder {mapped} that "$path" maps already has a child named {name})`
				)
				continue
			end
		end
		local existing = service.vals[name]
		if existing == nil then
			SP.set(service, name, node)
			table.insert(added, serviceName .. "." .. name)
		elseif not AdoptInit.isOurs(existing, gameId) then
			table.insert(clashes, serviceName .. "." .. name)
		elseif serviceName == "ServerScriptService" and name == "Modules" then
			local own = existing.vals[moduleName]
			if own == nil then
				SP.set(existing, moduleName, node.vals[moduleName])
				table.insert(added, serviceName .. ".Modules." .. moduleName)
			end
		elseif serviceName == "ReplicatedStorage" and name == "GameModule" then
			for _, part in { "module", "client" } do
				if existing.vals[part] == nil then
					SP.set(existing, part, node.vals[part])
					table.insert(added, serviceName .. ".GameModule." .. part)
				end
			end
		end
	end
	if #clashes > 0 then
		return nil, {}, clashes
	end
	-- the spec files, READMEs and Blink sources in studwork/ stay out of the build
	local globs = project.vals.globIgnorePaths
	if globs == nil then
		globs = { __array = true, items = {} }
		SP.set(project, "globIgnorePaths", globs)
	end
	if type(globs) == "table" and globs.__array then
		for _, pattern in AdoptInit.GLOB_IGNORE do
			if not table.find(globs.items, pattern) then
				table.insert(globs.items, pattern)
				table.insert(added, "globIgnorePaths " .. pattern)
			end
		end
	end
	return SP.encode(project), added, clashes
end

function AdoptInit.parseFindings(text: string): { any }
	local out = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		local path, n, check, message = string.match(line, "^(.-):(%d+): %[([%w_%-]+)%] (.*)$")
		if path and not string.find(path, "^warning") then
			path = string.gsub(path, "^%./", "")
			table.insert(out, { path = path, line = tonumber(n), check = check, message = message })
		end
	end
	return out
end

-- (v1.6.0 dogfood r2) what to do about a must-fix file, said exactly
function AdoptInit.mustFixMessage(path: string, gameId: string, checks: { string }?): string
	local list = checks or {}
	if #list == 0 or table.find(list, "purchases") then
		return `must fix before lint passes: port every product of {path} to ctx.shop.onProduct in modules/{gameId}/server/init.luau and delete the ProcessReceipt assignment before the first commit (products aren't granted on this branch until then)`
	end
	return `must fix before lint passes: {path} ({table.concat(list, ", ")} findings are never downgraded by studwork-legacy.json; fix them before the first commit)`
end

function AdoptInit.mustFix(f: any): boolean
	if f.check == "special" or f.check == "packages" then
		return true
	end
	return f.check == "purchases" and string.find(f.message, "ProcessReceipt", 1, true) ~= nil
end

-- what the audit report (studwork-adopt-report.json, §1) says about a file
local function auditNotes(report: any?): { [string]: { [string]: boolean } }
	local notes = {}
	local function note(file: any, what: string)
		if type(file) == "string" then
			file = string.gsub(file, "^%./", "")
			notes[file] = notes[file] or {}
			notes[file][what] = true
		end
	end
	if type(report) ~= "table" then
		return notes
	end
	for _, ds in report.datastores or {} do
		for _, call in ds.calls or {} do
			note(call.file, "old save code (DataStore " .. tostring(ds.name) .. ")")
		end
	end
	for _, lib in report.libraries or {} do
		note(lib.file, "old save code (" .. tostring(lib.name) .. ")")
	end
	local purchases = report.purchases or {}
	for _, list in { purchases.processReceipt, purchases.products, purchases.passes } do
		for _, p in list or {} do
			note(p.file, "old purchase code")
		end
	end
	for _, r in report.remotes or {} do
		for _, h in r.handlers or {} do
			note(h.file, "old remote handlers")
		end
	end
	return notes
end

-- (v1.6.0 dogfood r3) the reason of an entry that lists only the "style" pseudo-check
AdoptInit.STYLE_REASON =
	"old code before StudWork: not held to selene/StyLua/strict typing (style); port or delete it"

function AdoptInit.legacyList(
	findings: { any },
	report: any?,
	oldSources: { string }?
): (any, any, { string }, { [string]: { string } })
	local byFile = {}
	-- (v1.6.0 dogfood r3) every old Luau source gets the "style" pseudo-check: old code is never held
	-- to selene/StyLua/strict typing, so a fresh project's first tools/lint and tools/typecheck
	-- pass. "style" has no count: a style-only file's baseline entry is {} (so a later entry is
	-- still refused)
	local style = {}
	for _, p in oldSources or {} do
		style[p] = true
		byFile[p] = byFile[p] or {}
	end
	local mustFix = {}
	local mustFixChecks = {}
	for _, f in findings do
		byFile[f.path] = byFile[f.path] or {}
		byFile[f.path][f.check] = (byFile[f.path][f.check] or 0) + 1
		if AdoptInit.mustFix(f) then
			if not table.find(mustFix, f.path) then
				table.insert(mustFix, f.path)
				mustFixChecks[f.path] = {}
			end
			if not table.find(mustFixChecks[f.path], f.check) then
				table.insert(mustFixChecks[f.path], f.check)
				table.sort(mustFixChecks[f.path])
			end
		end
	end
	table.sort(mustFix)
	local paths = {}
	for p in byFile do
		table.insert(paths, p)
	end
	table.sort(paths)
	local notes = auditNotes(report)
	local list = { files = {} }
	local baseline = { files = {} }
	for _, p in paths do
		local checks = {}
		for c in byFile[p] do
			table.insert(checks, c)
		end
		local counted = table.clone(checks)
		table.sort(counted)
		if style[p] then
			table.insert(checks, "style")
		end
		table.sort(checks)
		local reason
		if #counted == 0 then
			reason = AdoptInit.STYLE_REASON
		elseif notes[p] then
			local parts = {}
			for what in notes[p] do
				table.insert(parts, what)
			end
			table.sort(parts)
			reason = table.concat(parts, "; ") .. " before StudWork (audit); port it, then remove this entry"
		else
			reason = "existing code before StudWork: " .. table.concat(counted, ", ")
		end
		table.insert(list.files, { path = p, checks = checks, reason = reason })
		-- (v1.6.0 final review M2) "style" is anchored in the baseline as `style = 0` (never a
		-- count), so a later commit can't add it to an entry to silence selene/StyLua/typecheck
		local base = table.clone(byFile[p])
		if style[p] then
			base.style = 0
		end
		baseline.files[p] = base
	end
	return list, baseline, mustFix, mustFixChecks
end

-- (v1.6.0 dogfood r2) the product / pass ids the audit report found, as sorted, unique lists
function AdoptInit.reportProducts(report: any?): ({ number }, { number })
	local products, passes = {}, {}
	local purchases = if type(report) == "table" and type(report.purchases) == "table"
		then report.purchases
		else {}
	local function collect(list: any, into: { number })
		if type(list) ~= "table" then
			return
		end
		for _, p in list do
			local id = type(p) == "table" and p.id
			if type(id) == "number" and id > 0 and id == math.floor(id) and not table.find(into, id) then
				table.insert(into, id)
			end
		end
	end
	collect(purchases.products, products)
	collect(purchases.passes, passes)
	table.sort(products)
	table.sort(passes)
	return products, passes
end

-- (v1.6.0 dogfood r2) the minimal GameConfig of an adopted game without src/shared/Config:
-- the chosen modules, each at its defaults (a commented line), no items / rarity tables /
-- starter items / events, compliance.paidCurrencies = {}, and the audit's product and pass ids
-- under placeholder names. `template` = templates/adopt/config/init.luau.tmpl,
-- `render` = NewProject.render.
function AdoptInit.renderConfig(
	template: string,
	render: (string, { [string]: string }) -> (string?, string?),
	gameId: string,
	modules: { string },
	report: any?
): (string?, string?)
	local moduleLines, kitLines = {}, {}
	for _, name in modules do
		table.insert(moduleLines, `\t\trequire(Modules:WaitForChild("{name}"):WaitForChild("module")),\n`)
		if name == "Items" then
			table.insert(kitLines, "\t\t-- Items has no config: item definitions are `items` below.\n")
		else
			table.insert(kitLines, `\t\t-- {name} = \{\}, -- at its defaults\n`)
		end
	end
	local products, passes = AdoptInit.reportProducts(report)
	local productLines, passLines = {}, {}
	for _, id in products do
		table.insert(productLines, `\t\t\tProduct{id} = {id}, -- TODO: name it (the audit found this id)\n`)
	end
	for _, id in passes do
		table.insert(passLines, `\t\t\tPass{id} = {id}, -- TODO: name it (the audit found this id)\n`)
	end
	local header = if #modules > 0
		then 'local ReplicatedStorage = game:GetService("ReplicatedStorage")\nlocal Modules = ReplicatedStorage:WaitForChild("Modules")\n'
		else ""
	return render(template, {
		gameId = gameId,
		modulesHeader = header,
		modules = table.concat(moduleLines),
		kitConfig = table.concat(kitLines),
		devProducts = table.concat(productLines),
		passes = table.concat(passLines),
	})
end

function AdoptInit.storeCollision(report: any?, gameId: string): string?
	if type(report) ~= "table" then
		return nil
	end
	local own = { ["PlayerData_" .. gameId] = true, ["PlayerData_" .. gameId .. "_Studio"] = true }
	for _, ds in report.datastores or {} do
		if own[ds.name] then
			return ds.name
		end
	end
	for _, lib in report.libraries or {} do
		if own[lib.store] then
			return lib.store
		end
	end
	return nil
end

-- ordered JSON nodes from plain values with an explicit key order (sorted otherwise)
local function sortedNode(SP, map: { [string]: any }, leaf: (any) -> any): any
	local keys = {}
	for k in map do
		table.insert(keys, k)
	end
	table.sort(keys)
	local node = SP.newObject()
	for _, k in keys do
		SP.set(node, k, leaf(map[k]))
	end
	return node
end

function AdoptInit.baselineNode(SP, baseline: any): any
	local files = sortedNode(SP, (baseline and baseline.files) or {}, function(checks)
		return sortedNode(SP, checks, function(n)
			return n
		end)
	end)
	local node = SP.newObject()
	SP.set(node, "files", files)
	return node
end

function AdoptInit.renderStudworkJson(SP, placeFile: string?, baseline: any?): string
	local node = SP.newObject()
	SP.set(node, "layout", "single-game")
	SP.set(node, "framework", "studwork")
	SP.set(node, "adopted", true)
	if placeFile then
		SP.set(node, "placeFile", placeFile)
	end
	SP.set(node, "legacyBaseline", AdoptInit.baselineNode(SP, baseline or { files = {} }))
	return SP.encode(node)
end

function AdoptInit.renderLegacyJson(SP, list: any): string
	local node = SP.newObject()
	local files = { __array = true, items = {} }
	for _, entry in list.files do
		local e = SP.newObject()
		SP.set(e, "path", entry.path)
		SP.set(e, "checks", { __array = true, items = table.clone(entry.checks) })
		SP.set(e, "reason", entry.reason)
		table.insert(files.items, e)
	end
	SP.set(node, "files", files)
	return SP.encode(node)
end

function AdoptInit.mergeGitignore(existing: string?, template: string): string?
	local have = {}
	for line in string.gmatch(existing or "", "[^\r\n]+") do
		have[string.match(line, "^%s*(.-)%s*$")] = true
	end
	local missing = {}
	for line in string.gmatch(template, "[^\r\n]+") do
		local l = string.match(line, "^%s*(.-)%s*$")
		if l ~= "" and string.sub(l, 1, 1) ~= "#" and not have[l] then
			table.insert(missing, l)
			have[l] = true
		end
	end
	if #missing == 0 then
		return nil
	end
	local out = existing or ""
	if out ~= "" and string.sub(out, -1) ~= "\n" then
		out ..= "\n"
	end
	if out ~= "" then
		out ..= "\n"
	end
	return out .. "# StudWork (tools/adopt --init)\n" .. table.concat(missing, "\n") .. "\n"
end

function AdoptInit.dependsOnLines(modules: { string }): string
	local out = {}
	for _, m in modules do
		table.insert(out, '\t\trequire(KitDefs:WaitForChild("' .. m .. '"):WaitForChild("module")),\n')
	end
	return table.concat(out)
end

local function splitLines(text: string): { string }
	local lines = {}
	for line in string.gmatch(text, "([^\n]*)\n") do
		table.insert(lines, line)
	end
	local tail = string.match(text, "([^\n]+)$")
	if tail then
		table.insert(lines, tail)
	end
	return lines
end

-- LCS-based line diff; prints changed lines with 2 lines of context (enough for a review)
function AdoptInit.lineDiff(old: string, new: string): string
	local a, b = splitLines(old), splitLines(new)
	local n, m = #a, #b
	local dp = {}
	for i = n + 1, 1, -1 do
		dp[i] = {}
		for j = m + 1, 1, -1 do
			if i > n or j > m then
				dp[i][j] = 0
			elseif a[i] == b[j] then
				dp[i][j] = dp[i + 1][j + 1] + 1
			else
				dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1])
			end
		end
	end
	local ops = {}
	local i, j = 1, 1
	while i <= n or j <= m do
		if i <= n and j <= m and a[i] == b[j] then
			table.insert(ops, { " ", a[i] })
			i += 1
			j += 1
		elseif i <= n and (j > m or dp[i + 1][j] >= dp[i][j + 1]) then
			table.insert(ops, { "-", a[i] })
			i += 1
		else
			table.insert(ops, { "+", b[j] })
			j += 1
		end
	end
	local keep = {}
	for k, op in ops do
		if op[1] ~= " " then
			for c = math.max(1, k - 2), math.min(#ops, k + 2) do
				keep[c] = true
			end
		end
	end
	local out = {}
	local gap = false
	for k, op in ops do
		if keep[k] then
			table.insert(out, op[1] .. op[2])
			gap = false
		elseif not gap then
			table.insert(out, "@@")
			gap = true
		end
	end
	return table.concat(out, "\n")
end

return AdoptInit
