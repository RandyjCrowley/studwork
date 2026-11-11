--!nocheck
--[[
	tools/lune/adopt-init (StudWork v1.6.0): the Lune side of `tools/adopt --init`
	(tools/_adopt-init, docs/framework/adopting.md §2). Pure parts: AdoptInit.luau. Runs from the
	StudWork checkout running the tool; every project path is absolute and every write is under it.

	  lune run tools/lune/adopt-init parse <args...>
	      validates the arguments; prints `key<TAB>value` lines for the bash side (exit 1 on error)
	  lune run tools/lune/adopt-init plan <project> <templates> <gameId> <tag> <modules|-> dry|apply
	      <project> = the project's absolute folder, <templates> = an absolute templates/ folder (the
	      project's studwork/templates, or this checkout's for --dry-run). Prints one line per target:
	        create<TAB><rel>     a file init creates (apply: written)
	        merge<TAB><rel>      a file init changes (dry: followed by a diff, lines starting "  ")
	        same<TAB><rel>       already as init would write it
	        skip<TAB><rel><TAB><why>   an existing file init leaves alone
	        clash<TAB><what>     a project-file entry StudWork needs is taken (exit 3, nothing written)
	        collision<TAB><store>   the audit found an old store StudWork's own store would collide
	                             with (exit 4, nothing written)
	        note<TAB><text>
	      Never overwrites a file it doesn't merge; the merged files are the project file and
	      .gitignore.
	  lune run tools/lune/adopt-init legacy <project> <findings file> dry|apply [<gameId>]
	      the guardrails findings (the text `guardrails --raw` prints) -> studwork-legacy.json and
	      studwork.json's legacyBaseline. The bash side calls it only on the run that created
	      studwork.json (a committed baseline is never rewritten).
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local AdoptInit = require("./AdoptInit")
local SyncProjects = require("./SyncProjects")
local NewGame = require("./NewGame")
local NewProject = require("./NewProject")

local args = table.clone(process.args)
local cmd = table.remove(args, 1)

local function readJson(path: string): any?
	if not fs.isFile(path) then
		return nil
	end
	local ok, value = pcall(serde.decode, "json", fs.readFile(path))
	return if ok then value else nil
end

if cmd == "parse" then
	local opts, err = AdoptInit.parseArgs(args, NewGame.validName)
	if opts == nil then
		print("error: " .. tostring(err))
		process.exit(1)
	end
	if opts.modules and #opts.modules == 1 and string.lower(opts.modules[1]) == "none" then
		-- (v1.6.0 dogfood r2) --modules none: no kit module (the game module alone)
		opts.modules = nil
		opts.noModules = true
	end
	if opts.modules then
		local KitModules = require("./KitModules")
		local order, added, errors = NewGame.resolveModules(KitModules.load(fs), opts.modules)
		if order == nil then
			print("error: --modules:")
			for _, e in errors do
				print("  - " .. e)
			end
			process.exit(1)
		end
		for _, note in added do
			print("note: added dependency " .. note)
		end
		opts.modules = order
	end
	local function out(key: string, value: string?)
		if value ~= nil then
			assert(not string.find(value, "[\t\n]"), key .. " contains a tab or newline")
			print(key .. "\t" .. value)
		end
	end
	out("path", opts.path)
	out("name", opts.name)
	out(
		"modules",
		if opts.noModules then "none" elseif opts.modules then table.concat(opts.modules, ",") else nil
	)
	out("url", opts.url)
	out("tag", opts.tag)
	out("dryRun", if opts.dryRun then "1" else "0")
	out("install", if opts.install then "1" else "0")
	process.exit(0)
end

local function absProject(dir: string?): string
	if dir == nil or string.sub(dir, 1, 1) ~= "/" or not fs.isDir(dir) then
		print("error: needs the project's absolute folder: " .. tostring(dir))
		process.exit(2)
	end
	return (string.gsub(dir :: string, "/+$", ""))
end

if cmd == "plan" then
	local project = absProject(args[1])
	local templates, gameId, tag, modulesArg, mode = args[2], args[3], args[4], args[5], args[6]
	if
		templates == nil
		or gameId == nil
		or tag == nil
		or modulesArg == nil
		or (mode ~= "dry" and mode ~= "apply")
	then
		print("usage: adopt-init plan <project> <templates> <gameId> <tag> <modules|-> dry|apply")
		process.exit(2)
	end
	local apply = mode == "apply"
	local function at(rel: string): string
		assert(AdoptInit.isSafeRel(rel), "unsafe path " .. rel)
		return project .. "/" .. rel
	end

	-- the project file and the merge (a clash stops everything before any write)
	local projectFile, pfErr = AdoptInit.findProjectFile(fs.readDir(project))
	if projectFile == nil then
		print("error: " .. tostring(pfErr))
		process.exit(1)
	end
	local report = readJson(at("studwork-adopt-report.json"))
	local collision = AdoptInit.storeCollision(report, gameId)
	if collision then
		print("collision\t" .. collision)
		process.exit(4)
	end
	if report == nil then
		print(
			"note\tno studwork-adopt-report.json (run tools/adopt --audit first): the store-name check and the legacy reasons need it"
		)
	end
	local oldProject = fs.readFile(at(projectFile))
	local okMerge, merged, added, clashes = pcall(
		AdoptInit.mergeProject,
		SyncProjects,
		oldProject,
		gameId,
		function(path: string, name: string): boolean
			local dir = at(path)
			if not fs.isDir(dir) then
				return false
			end
			for _, e in fs.readDir(dir) do
				-- Rojo's sync name: the file name without .server/.client/.luau/.lua/.meta.json/.model.json
				local base = string.gsub(e, "%.server%.luau$", "")
				base = string.gsub(base, "%.client%.luau$", "")
				base = string.gsub(base, "%.server%.lua$", "")
				base = string.gsub(base, "%.client%.lua$", "")
				base = string.gsub(base, "%.model%.json$", "")
				base = string.gsub(base, "%.luau$", "")
				base = string.gsub(base, "%.lua$", "")
				if base == name then
					return true
				end
			end
			return false
		end
	)
	if not okMerge then
		print("error: " .. projectFile .. ": " .. tostring(merged))
		process.exit(1)
	end
	if merged == nil then
		for _, c in clashes do
			print("clash\t" .. c)
		end
		process.exit(3)
	end

	-- every file, as { rel, text, mode = "create" | "merge" }
	local writes = {}
	local function create(rel: string, text: string)
		table.insert(writes, { rel = rel, text = text, kind = "create" })
	end
	local function render(path: string, vars: { [string]: string }): string
		local text, err = NewProject.render(fs.readFile(path), vars)
		if text == nil then
			print("error: " .. path .. ": " .. tostring(err))
			process.exit(1)
		end
		return text
	end

	local KitModules = require("./KitModules")
	local Modules = KitModules.load(fs)
	local chosen = if modulesArg == "-" or modulesArg == ""
		then nil
		elseif modulesArg == "none" then {}
		else string.split(modulesArg, ",")
	local moduleList = chosen or Modules.ORDER
	local moduleName = AdoptInit.moduleName(gameId)

	-- studwork.json (the legacy baseline is added by `legacy` on the run that creates it)
	local placeFile = nil
	if fs.isFile(at(".studwork-from-place.json")) then
		local manifest = readJson(at(".studwork-from-place.json"))
		if type(manifest) == "table" and type(manifest.placeFile) == "string" then
			placeFile = manifest.placeFile
		else
			local places = {}
			for _, e in fs.readDir(project) do
				if string.match(e, "%.rbxlx?$") and fs.isFile(at(e)) then
					table.insert(places, e)
				end
			end
			table.sort(places)
			if #places == 1 then
				placeFile = places[1]
			else
				print(
					"note\t.studwork-from-place.json found but no single place file at the root: placeFile not set"
				)
			end
		end
		if placeFile and not AdoptInit.isSafeRel(placeFile) then
			print("note\tthe from-place manifest's placeFile is not a project-relative path: not set")
			placeFile = nil
		end
	end
	if fs.isFile(at("studwork.json")) then
		local marker = readJson(at("studwork.json"))
		if not (type(marker) == "table" and marker.adopted == true) then
			print("error: studwork.json exists and is not an adopted project's (already a StudWork project?)")
			process.exit(1)
		end
	else
		create("studwork.json", AdoptInit.renderStudworkJson(SyncProjects, placeFile, nil))
	end

	-- the tool wrappers and the hook (from templates/single-game)
	local single = templates .. "/single-game"
	local wrappers = fs.readDir(single .. "/tools")
	table.sort(wrappers)
	for _, w in wrappers do
		if w ~= ".DS_Store" then
			create("tools/" .. w, fs.readFile(single .. "/tools/" .. w))
		end
	end
	create(".githooks/pre-commit", fs.readFile(single .. "/.githooks/pre-commit"))

	-- the game module
	local vars = {
		gameId = gameId,
		Module = moduleName,
		tag = tag,
		dependsOn = AdoptInit.dependsOnLines(moduleList),
		projectFile = projectFile,
	}
	local moduleSource = render(templates .. "/adopt/module.luau.tmpl", vars)
	if #moduleList == 0 then
		moduleSource = string.gsub(moduleSource, "local KitDefs = [^\n]*\n", "")
	end
	local moduleDir = "modules/" .. gameId
	create(moduleDir .. "/module.luau", moduleSource)
	create(moduleDir .. "/server/init.luau", render(templates .. "/adopt/server/init.luau.tmpl", vars))
	create(moduleDir .. "/module.spec.luau", render(templates .. "/adopt/module.spec.luau.tmpl", vars))
	create(moduleDir .. "/client/init.luau", render(templates .. "/adopt/client/init.luau.tmpl", vars))
	create(moduleDir .. "/README.md", render(templates .. "/adopt/README.md.tmpl", vars))

	-- the boot scripts (StudWork.start on both sides), mapped by the merged project file
	for _, f in { "server/Main.server.luau", "server/ServerConfig.luau", "client/Main.client.luau" } do
		create("studwork-boot/" .. f, fs.readFile(templates .. "/adopt/boot/" .. f))
	end

	-- src/shared/Config (only when the game has none): a MINIMAL GameConfig (templates/adopt/config,
	-- v1.6.0 dogfood r2): the chosen modules at their defaults, the audit's product ids, nothing
	-- of the new-game sandbox (its items, rarity tables, starter items and events aren't this game's)
	if not fs.isDir(at("src/shared/Config")) then
		local text, err = AdoptInit.renderConfig(
			fs.readFile(templates .. "/adopt/config/init.luau.tmpl"),
			NewProject.render,
			gameId,
			moduleList,
			report
		)
		if text == nil then
			print("error: templates/adopt/config/init.luau.tmpl: " .. tostring(err))
			process.exit(1)
		end
		create("src/shared/Config/init.luau", text)
	else
		print(
			"note\tsrc/shared/Config exists: kept as it is (GameConfig.modules must list the kits the game module depends on)"
		)
	end

	-- merged files
	local writesMerged = {}
	table.insert(writesMerged, { rel = projectFile, old = oldProject, text = merged })
	local gitignoreTemplate = fs.readFile(single .. "/gitignore")
	if placeFile then
		-- a Studio-only game keeps its place file in the repo
		gitignoreTemplate = string.gsub(gitignoreTemplate, "\n%*%.rbxlx?\n", "\n")
		gitignoreTemplate = string.gsub(gitignoreTemplate, "\n%*%.rbxlx?\n", "\n")
	end
	local oldIgnore = if fs.isFile(at(".gitignore")) then fs.readFile(at(".gitignore")) else nil
	local newIgnore = AdoptInit.mergeGitignore(oldIgnore, gitignoreTemplate)
	if newIgnore then
		table.insert(writesMerged, { rel = ".gitignore", old = oldIgnore or "", text = newIgnore })
	else
		print("same\t.gitignore")
	end

	-- decide every create: missing -> create; identical -> same; different -> skip (never overwrite)
	local final = {}
	for _, w in writes do
		local path = at(w.rel)
		if fs.isFile(path) then
			local current = fs.readFile(path)
			if current == w.text then
				print("same\t" .. w.rel)
			elseif string.sub(w.rel, 1, 6) == "tools/" and string.find(current, "_studwork", 1, true) then
				print("skip\t" .. w.rel .. "\ta StudWork wrapper that differs from this release's: kept")
			else
				print("skip\t" .. w.rel .. "\texists and is not StudWork's: left alone")
			end
		elseif fs.isDir(path) then
			print("skip\t" .. w.rel .. "\ta folder is in the way: left alone")
		else
			print("create\t" .. w.rel)
			table.insert(final, w)
		end
	end
	for _, w in writesMerged do
		if w.old == w.text then
			print("same\t" .. w.rel)
		else
			print("merge\t" .. w.rel)
			if not apply then
				for line in string.gmatch(AdoptInit.lineDiff(w.old, w.text) .. "\n", "([^\n]*)\n") do
					print("  " .. line)
				end
			end
			table.insert(final, w)
		end
	end
	if #added > 0 and not apply then
		print("note\tproject entries added: " .. table.concat(added, ", "))
	end
	if apply then
		for _, w in final do
			local path = at(w.rel)
			local parent = string.match(path, "^(.*)/[^/]+$")
			if parent and not fs.isDir(parent) then
				fs.writeDir(parent)
			end
			fs.writeFile(path, w.text)
		end
	end
	process.exit(0)
end

if cmd == "legacy" then
	local project = absProject(args[1])
	local findingsFile, mode = args[2], args[3]
	if findingsFile == nil or (mode ~= "dry" and mode ~= "apply") then
		print("usage: adopt-init legacy <project> <findings file> dry|apply [<gameId>]")
		process.exit(2)
	end
	local findings = AdoptInit.parseFindings(fs.readFile(findingsFile))
	local report = readJson(project .. "/studwork-adopt-report.json")
	local gameId = args[4]
	local list, baseline, mustFix, mustFixChecks = AdoptInit.legacyList(findings, report)
	local marker = readJson(project .. "/studwork.json")
	if type(marker) ~= "table" or marker.adopted ~= true then
		print("error: studwork.json is missing or not adopted")
		process.exit(1)
	end
	local placeFile = if type(marker.placeFile) == "string" then marker.placeFile else nil
	local studworkJson = AdoptInit.renderStudworkJson(SyncProjects, placeFile, baseline)
	local legacyJson = AdoptInit.renderLegacyJson(SyncProjects, list)
	if mode == "apply" then
		fs.writeFile(project .. "/studwork.json", studworkJson)
		if not fs.isFile(project .. "/studwork-legacy.json") then
			fs.writeFile(project .. "/studwork-legacy.json", legacyJson)
		end
	end
	print(
		`legacy: {#list.files} file(s), {#findings} finding(s) in studwork-legacy.json and the legacyBaseline`
	)
	for _, entry in list.files do
		print(`  {entry.path}: {table.concat(entry.checks, ", ")}`)
	end
	for _, path in mustFix do
		print(AdoptInit.mustFixMessage(path, gameId or "<gameId>", mustFixChecks[path]))
	end
	process.exit(0)
end

print("usage: adopt-init parse|plan|legacy ...")
process.exit(2)
