--!strict
--[[
	tools/lune/Layout: pure checks of the core v1.3.0 repo layout, shared by tools/doctor and
	tools/core-status (zero requires; callers read the files). Specs: Layout.spec.luau.

	The layout (core-v1.3.0 Phase 2):
	  packages/framework/{shared,server,client}   the StudWork runtime (StudWork.VERSION in
	                                              shared/init.luau)
	  packages/kits/<kit>/{shared,server}         the built-in kits (collection, economy, ...)
	  packages/ui                                 the UI kit
	  packages/core                               GONE (the v1.2 facade, deleted in Phase 2)

	Layout.repoIssues(exists)                     -> { string }  exists(path) -> boolean
	Layout.projectIssues(project, gameDir, kits)  -> { string }  one game's *.project.json:
	    ReplicatedStorage.Framework -> packages/framework/shared, FrameworkClient -> .../client,
	    ServerScriptService.Framework -> .../server, Kits.<Kit> -> packages/kits/<kit>/shared|server
	    for every kit it maps, and no $path into packages/core
	Layout.projectKits(project)                   -> { string }  the kit names a project maps
	    (ReplicatedStorage.Kits children), sorted
	Layout.normalize(path)                        -> string      collapses "a/b/../c" and "./"
]]

local Layout = {}

Layout.FRAMEWORK = "packages/framework"
Layout.KITS_DIR = "packages/kits"
Layout.REMOVED = { "packages/core", "packages/kits/compat" }

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
function Layout.repoIssues(exists: (string) -> boolean, kits: { string }): { string }
	local issues = {}
	for _, sub in { "shared", "server", "client" } do
		if not exists(Layout.FRAMEWORK .. "/" .. sub) then
			table.insert(issues, `{Layout.FRAMEWORK}/{sub} is missing`)
		end
	end
	if not exists(Layout.FRAMEWORK .. "/shared/init.luau") then
		table.insert(issues, `{Layout.FRAMEWORK}/shared/init.luau (StudWork.VERSION) is missing`)
	end
	if #kits == 0 then
		table.insert(issues, `no kits under {Layout.KITS_DIR}`)
	end
	for _, kit in kits do
		for _, sub in { "shared", "server" } do
			if not exists(`{Layout.KITS_DIR}/{kit}/{sub}`) then
				table.insert(issues, `{Layout.KITS_DIR}/{kit}/{sub} is missing`)
			end
		end
	end
	for _, removed in Layout.REMOVED do
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

function Layout.projectKits(project: any): { string }
	local kits = child(child(child(project, "tree"), "ReplicatedStorage"), "Kits")
	local out = {}
	if type(kits) == "table" then
		for name, node in kits do
			if type(name) == "string" and string.sub(name, 1, 1) ~= "$" and type(node) == "table" then
				table.insert(out, name)
			end
		end
	end
	table.sort(out)
	return out
end

function Layout.projectIssues(project: any, gameDir: string, kits: { string }): { string }
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
	expect(child(rs, "Framework"), "ReplicatedStorage.Framework", Layout.FRAMEWORK .. "/shared")
	expect(child(rs, "FrameworkClient"), "ReplicatedStorage.FrameworkClient", Layout.FRAMEWORK .. "/client")
	expect(child(sss, "Framework"), "ServerScriptService.Framework", Layout.FRAMEWORK .. "/server")
	local known: { [string]: string } = {}
	for _, kit in kits do
		known[string.lower(kit)] = kit
	end
	for _, name in Layout.projectKits(project) do
		local folder = known[string.lower(name)]
		if folder == nil then
			table.insert(
				issues,
				`ReplicatedStorage.Kits.{name}: no kit '{string.lower(name)}' under {Layout.KITS_DIR}`
			)
		else
			expect(
				child(child(rs, "Kits"), name),
				"ReplicatedStorage.Kits." .. name,
				`{Layout.KITS_DIR}/{folder}/shared`
			)
			expect(
				child(child(sss, "Kits"), name),
				"ServerScriptService.Kits." .. name,
				`{Layout.KITS_DIR}/{folder}/server`
			)
		end
	end
	local paths = {}
	allPaths(tree, gameDir, "", paths)
	for _, entry in paths do
		for _, removed in Layout.REMOVED do
			if entry.path == removed or string.sub(entry.path, 1, #removed + 1) == removed .. "/" then
				table.insert(issues, `{entry.at} maps {entry.path} (removed in core v1.3.0)`)
			end
		end
	end
	return issues
end

return Layout
