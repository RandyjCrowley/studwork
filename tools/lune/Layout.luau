--!strict
--[[
	tools/lune/Layout: pure checks of the core v1.3.0 repo layout, shared by tools/doctor and
	tools/core-status (zero requires; callers read the files). Specs: Layout.spec.luau.

	The layout (v1.3.0; kits one folder per module since v1.3.1, R19):
	  packages/framework/{shared,server,client}   the StudWork runtime (StudWork.VERSION in
	                                              shared/init.luau)
	  packages/kits/<kit>/<Module>/module.luau    the built-in kits' modules (collection, economy,
	                                              ...), each with server/, client/, shared/ parts
	  packages/kits/<kit>/{shared,server}         GONE (the pre-v1.3.1 kit layout)
	  packages/ui                                 the UI kit
	  packages/core                               GONE (the v1.2 facade, deleted in v1.3.0)

	Layout.repoIssues(exists, kits, kitModules?)  -> { string }  exists(path) -> boolean;
	    kitModules = { [kit] = { <Module folder> } } (a kit with none is reported)
	Layout.projectIssues(project, gameDir, kits)  -> { string }  one game's *.project.json:
	    ReplicatedStorage.Framework -> packages/framework/shared, FrameworkClient -> .../client,
	    ServerScriptService.Framework -> .../server, no `Kits` folder, every kit module entry
	    ReplicatedStorage.Modules.<M>.module -> packages/kits/<kit>/<M>/module.luau (and
	    ServerScriptService.Modules.<M> -> .../<M>/server), and no $path into packages/core
	Layout.projectKits(project)                   -> { string }  the kit modules a project maps
	    (ReplicatedStorage.Modules children whose module is under packages/kits), sorted
	Layout.normalize(path)                        -> string      collapses "a/b/../c" and "./"
	repoIssues / projectIssues take an optional last argument coreDir (StudWork v1.4.0): the core's
	folder relative to the project ("roblox-core" in a games repo); every expected path is under it.
]]

local Layout = {}

Layout.FRAMEWORK = "packages/framework"
Layout.KITS_DIR = "packages/kits"
Layout.REMOVED = { "packages/core", "packages/kits/compat" }

-- A core path as seen from the project root (coreDir: "." / nil in the core repo, "roblox-core"
-- in a games repo; StudWork v1.4.0, tools/lune/Roots.luau).
local function under(coreDir: string?, path: string): string
	if coreDir == nil or coreDir == "" or coreDir == "." then
		return path
	end
	return coreDir .. "/" .. path
end
Layout.under = under

function Layout.normalize(path: string): string
	local parts: { string } = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			if #parts > 0 and parts[#parts] ~= ".." then
				table.remove(parts)
			else
				table.insert(parts, part)
			end
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return table.concat(parts, "/")
end

-- Repo-level checks. `exists(path)` answers for files and folders.
function Layout.repoIssues(
	exists: (string) -> boolean,
	kits: { string },
	kitModules: { [string]: { string } }?,
	coreDir: string?
): { string }
	local FRAMEWORK = under(coreDir, Layout.FRAMEWORK)
	local KITS_DIR = under(coreDir, Layout.KITS_DIR)
	local issues = {}
	for _, sub in { "shared", "server", "client" } do
		if not exists(FRAMEWORK .. "/" .. sub) then
			table.insert(issues, `{FRAMEWORK}/{sub} is missing`)
		end
	end
	if not exists(FRAMEWORK .. "/shared/init.luau") then
		table.insert(issues, `{FRAMEWORK}/shared/init.luau (StudWork.VERSION) is missing`)
	end
	if #kits == 0 then
		table.insert(issues, `no kits under {KITS_DIR}`)
	end
	for _, kit in kits do
		for _, sub in { "shared", "server" } do
			if exists(`{KITS_DIR}/{kit}/{sub}`) then
				table.insert(
					issues,
					`{KITS_DIR}/{kit}/{sub} is the pre-v1.3.1 kit layout (one folder per module: {KITS_DIR}/{kit}/<Module>/)`
				)
			end
		end
		local modules = if kitModules then kitModules[kit] else nil
		if kitModules and (modules == nil or #modules == 0) then
			table.insert(issues, `{KITS_DIR}/{kit} has no module folder (<Module>/module.luau)`)
		end
		for _, m in modules or {} do
			if not exists(`{KITS_DIR}/{kit}/{m}/module.luau`) then
				table.insert(issues, `{KITS_DIR}/{kit}/{m}/module.luau is missing`)
			end
		end
	end
	for _, removedPath in Layout.REMOVED do
		local removed = under(coreDir, removedPath)
		if exists(removed) then
			table.insert(issues, `{removed} still exists (removed in core v1.3.0; nothing may use it)`)
		end
	end
	return issues
end

local function child(node: any, name: string): any
	return if type(node) == "table" then node[name] else nil
end

local function pathOf(node: any, gameDir: string): string?
	local p = child(node, "$path")
	if type(p) ~= "string" then
		return nil
	end
	return Layout.normalize(gameDir .. "/" .. p)
end

-- Every $path in the tree, normalized against gameDir, with its Rojo location.
local function allPaths(node: any, gameDir: string, where: string, out: { { at: string, path: string } })
	if type(node) ~= "table" then
		return
	end
	local p = pathOf(node, gameDir)
	if p then
		table.insert(out, { at = where, path = p })
	end
	for name, sub in node do
		if type(name) == "string" and string.sub(name, 1, 1) ~= "$" then
			allPaths(sub, gameDir, if where == "" then name else where .. "." .. name, out)
		end
	end
end

local function kitModuleOf(path: string?, kitsDir: string?): (string?, string?, string?)
	-- packages/kits/<kit>/<Module>/<rest>
	if path == nil then
		return nil, nil, nil
	end
	local dir = string.gsub(kitsDir or Layout.KITS_DIR, "%p", "%%%0")
	return string.match(path, "^" .. dir .. "/([^/]+)/([^/]+)/?(.*)$")
end

local function moduleChildren(service: any): { string }
	local out = {}
	local modules = child(service, "Modules")
	if type(modules) == "table" then
		for name, node in modules do
			if type(name) == "string" and string.sub(name, 1, 1) ~= "$" and type(node) == "table" then
				table.insert(out, name)
			end
		end
	end
	table.sort(out)
	return out
end

function Layout.projectKits(project: any): { string }
	local rs = child(child(project, "tree"), "ReplicatedStorage")
	local out = {}
	for _, name in moduleChildren(rs) do
		local node = child(child(rs, "Modules"), name)
		local p = child(child(node, "module"), "$path")
		if type(p) == "string" and string.find(p, Layout.KITS_DIR .. "/", 1, true) then
			table.insert(out, name)
		end
	end
	return out
end

function Layout.projectIssues(project: any, gameDir: string, kits: { string }, coreDir: string?): { string }
	local FRAMEWORK = under(coreDir, Layout.FRAMEWORK)
	local KITS_DIR = under(coreDir, Layout.KITS_DIR)
	local issues = {}
	local tree = child(project, "tree")
	if type(tree) ~= "table" then
		return { "no tree" }
	end
	local rs = child(tree, "ReplicatedStorage")
	local sss = child(tree, "ServerScriptService")
	local function expect(node: any, where: string, want: string)
		local got = pathOf(node, gameDir)
		if got == nil then
			table.insert(issues, `{where} is not mapped (want {want})`)
		elseif got ~= want then
			table.insert(issues, `{where} maps {got} (want {want})`)
		end
	end
	expect(child(rs, "Framework"), "ReplicatedStorage.Framework", FRAMEWORK .. "/shared")
	expect(child(rs, "FrameworkClient"), "ReplicatedStorage.FrameworkClient", FRAMEWORK .. "/client")
	expect(child(sss, "Framework"), "ServerScriptService.Framework", FRAMEWORK .. "/server")
	local known: { [string]: boolean } = {}
	for _, kit in kits do
		known[kit] = true
	end
	for _, service in { { "ReplicatedStorage", rs }, { "ServerScriptService", sss } } do
		if child(service[2], "Kits") ~= nil then
			table.insert(
				issues,
				`{service[1]}.Kits: the pre-v1.3.1 kit layout (removed; run tools/sync-projects)`
			)
		end
	end
	-- kit module entries: ReplicatedStorage.Modules.<M>.module / ServerScriptService.Modules.<M>
	local projectDir = gameDir
	for _, name in moduleChildren(rs) do
		local node = child(child(rs, "Modules"), name)
		local where = "ReplicatedStorage.Modules." .. name
		local modulePath = pathOf(child(node, "module"), projectDir)
		local kit, folder, rest = kitModuleOf(modulePath, KITS_DIR)
		if kit ~= nil then
			if not known[kit :: string] then
				table.insert(issues, `{where}: no kit '{kit}' under {KITS_DIR}`)
			elseif folder ~= name or rest ~= "module.luau" then
				table.insert(
					issues,
					`{where}.module maps {modulePath} (want {KITS_DIR}/{kit}/{name}/module.luau)`
				)
			end
		end
	end
	for _, name in moduleChildren(sss) do
		local where = "ServerScriptService.Modules." .. name
		local serverPath = pathOf(child(child(sss, "Modules"), name), projectDir)
		local kit, folder, rest = kitModuleOf(serverPath, KITS_DIR)
		if kit ~= nil then
			if not known[kit :: string] then
				table.insert(issues, `{where}: no kit '{kit}' under {KITS_DIR}`)
			elseif folder ~= name or rest ~= "server" then
				table.insert(issues, `{where} maps {serverPath} (want {KITS_DIR}/{kit}/{name}/server)`)
			end
		end
	end
	local paths = {}
	allPaths(tree, gameDir, "", paths)
	for _, entry in paths do
		for _, removedPath in Layout.REMOVED do
			local removed = under(coreDir, removedPath)
			if entry.path == removed or string.sub(entry.path, 1, #removed + 1) == removed .. "/" then
				table.insert(issues, `{entry.at} maps {entry.path} (removed in core v1.3.0)`)
			end
		end
	end
	return issues
end

return Layout
