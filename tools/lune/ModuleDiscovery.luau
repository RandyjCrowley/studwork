--!nocheck
--[[
	tools/lune/ModuleDiscovery: the ONE place that finds the repo's shipped modules and maps them the
	way Rojo does (v1.3.1, R19: one folder per module, module-api.md §1). Used by the Lune
	testkit's fake `game` (tools/lune/testkit/harness.luau), the multi-server sim
	(packages/framework/test/sim/Server.luau), tools/sync-projects (the generated `Modules` entries
	of every *.project.json), tools/lune/KitModules and the guardrails.

	A module folder is any `packages/kits/<kit>/<Folder>/module.luau` or
	`examples/modules/<folder>/module.luau`. Its parts:
	  module.luau  -> ReplicatedStorage.Modules.<Name>.module
	  client/      -> ReplicatedStorage.Modules.<Name>.client   (only when the folder exists)
	  shared/      -> ReplicatedStorage.Modules.<Name>.shared   (only when the folder exists)
	  server/      -> ServerScriptService.Modules.<Name>         (only when the folder exists)
	  migrations/  -> ReplicatedStorage.Modules.<Name>.migrations (only when the folder exists;
	                  module.luau's `migrations = script.Parent.migrations`)
	<Name> is the definition's `name = "..."` (kits: always the folder name).

	Pure apart from the `fs` argument (@lune/fs or a fake with isDir/isFile/readDir/readFile), so
	the sim can load it with luau.load.

	ModuleDiscovery.ROOTS                         { "packages/kits/*", "examples/modules" }
	ModuleDiscovery.nameOf(source) -> string?     the defineModule `name`
	ModuleDiscovery.discover(fs, coreDir?) -> { Entry }   sorted by name; Entry = { name, dir, kit?,
	                                              module, client?, shared?, server?, blink? }
	ModuleDiscovery.children(entries, prefix?) -> { ReplicatedStorage = { [Name] = { module =
	                                              path, client = path?, shared = path? } },
	                                              ServerScriptService = { [Name] = path } }
	                                              (prefix is prepended to every path)
	coreDir (StudWork v1.4.0): the core's folder relative to the working directory ("." or nil in
	the core repo, "roblox-core" in a games repo, tools/lune/Roots.luau); every path is prefixed.
]]

local ModuleDiscovery = {}

ModuleDiscovery.KITS_DIR = "packages/kits"
ModuleDiscovery.EXAMPLES_DIR = "examples/modules"

function ModuleDiscovery.nameOf(source: string): string?
	local body = string.match(source, "defineModule%(%s*(%b{})")
	if body == nil then
		return nil
	end
	return string.match(body, '\n%s*name%s*=%s*"([%w_]+)"')
end

local function sorted(list: { string }): { string }
	local out = table.clone(list)
	table.sort(out)
	return out
end

local function entryAt(fs: any, dir: string, kit: string?): any?
	local modulePath = dir .. "/module.luau"
	if not fs.isFile(modulePath) then
		return nil
	end
	local folder = string.match(dir, "([^/]+)$")
	local name = ModuleDiscovery.nameOf(fs.readFile(modulePath)) or folder
	local entry = { name = name, dir = dir, kit = kit, module = modulePath }
	for _, part in { "client", "shared", "server", "migrations" } do
		if fs.isDir(dir .. "/" .. part) then
			entry[part] = dir .. "/" .. part
		end
	end
	if fs.isFile(dir .. "/net.blink") then
		entry.blink = dir .. "/net.blink"
	end
	return entry
end

local function under(coreDir: string?, path: string): string
	if coreDir == nil or coreDir == "" or coreDir == "." then
		return path
	end
	return coreDir .. "/" .. path
end

function ModuleDiscovery.discover(fs: any, coreDir: string?): { any }
	local out = {}
	local kitsDir = under(coreDir, ModuleDiscovery.KITS_DIR)
	local examplesDir = under(coreDir, ModuleDiscovery.EXAMPLES_DIR)
	if fs.isDir(kitsDir) then
		for _, kit in sorted(fs.readDir(kitsDir)) do
			local kitDir = kitsDir .. "/" .. kit
			if fs.isDir(kitDir) then
				for _, folder in sorted(fs.readDir(kitDir)) do
					local entry = fs.isDir(kitDir .. "/" .. folder)
						and entryAt(fs, kitDir .. "/" .. folder, kit)
					if entry then
						table.insert(out, entry)
					end
				end
			end
		end
	end
	if fs.isDir(examplesDir) then
		for _, folder in sorted(fs.readDir(examplesDir)) do
			local dir = examplesDir .. "/" .. folder
			local entry = fs.isDir(dir) and entryAt(fs, dir, nil)
			if entry then
				table.insert(out, entry)
			end
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

function ModuleDiscovery.children(entries: { any }, prefix: string?): any
	local p = prefix or ""
	local rs, sss = {}, {}
	for _, entry in entries do
		local holder = { module = p .. entry.module }
		if entry.client then
			holder.client = p .. entry.client
		end
		if entry.shared then
			holder.shared = p .. entry.shared
		end
		if entry.migrations then
			holder.migrations = p .. entry.migrations
		end
		rs[entry.name] = holder
		if entry.server then
			sss[entry.name] = p .. entry.server
		end
	end
	return { ReplicatedStorage = rs, ServerScriptService = sss }
end

return ModuleDiscovery
