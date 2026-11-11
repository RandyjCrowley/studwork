--!strict
--[[
	tools/lune/KitModules: the kit module manifest for tools (core-v1.3.0 step 4b-IIb), read from
	the kit module DEFINITIONS (packages/kits/<kit>/shared/<Module>.luau, defineModule) instead of
	the v1.2 packages/core/shared/Modules.luau. Pure helpers (no requires); the file reading is in
	KitModules.load(fs).

	KitModules.parse(files)  files = { [path] = source } -> manifest
	KitModules.load(fs)      reads packages/kits/*/shared/*.luau -> manifest
	manifest = {
	  ORDER     { string }                       the template's boot order (GameConfig.modules)
	  SPECS     { [name] = { kit, requires } }   requires = hard deps (defineModule dependsOn)
	  ACTIONS   { [action] = owner module }      client actions (shared/ModuleClients.luau ACTIONS)
	  FOUNDATION, isFoundation(name)             framework services (never listed)
	  kitFolder(name) -> "Collection" | ...      ReplicatedStorage.Kits.<folder> of a module
	  isModule(name) -> boolean
	  resolve(names) -> (ordered?, errors?)      hard deps listed, in ORDER
	}
]]

local KitModules = {}

-- Framework services (always on, never listed in GameConfig.modules; module-api.md §3).
KitModules.FOUNDATION = { "Data", "Policy", "Analytics", "Events", "Shop", "Net" }

-- The template's GameConfig.modules order (templates/new-game/src/shared/Config/init.luau); the
-- framework keeps list order for ties, so a generated list follows it.
KitModules.ORDER = {
	"Items",
	"Rarity",
	"Inventory",
	"Economy",
	"Upgrades",
	"Rebirth",
	"Offline",
	"Streak",
	"Friends",
	"Mail",
	"Plot",
}

local function parseDefinition(source: string): (string?, { string })
	local body = string.match(source, "defineModule%(%s*(%b{})")
	if body == nil then
		return nil, {}
	end
	local name = string.match(body, '\n\tname%s*=%s*"([%w_]+)"')
	local requires = {}
	local deps = string.match(body, "\n\tdependsOn%s*=%s*(%b{})")
	if deps then
		-- `dependsOn = { Items }` (a local required from script.Parent.<Name>) or
		-- `require(X:WaitForChild("Name"))`
		for quoted in string.gmatch(deps, 'WaitForChild%("([%w_]+)"%)%)') do
			table.insert(requires, quoted)
		end
		if #requires == 0 then
			for ident in string.gmatch(string.sub(deps, 2, -2), "([%a_][%w_]*)") do
				table.insert(requires, ident)
			end
		end
	end
	return name, requires
end

function KitModules.parse(files: { [string]: string }): any
	local specs: { [string]: any } = {}
	local actions: { [string]: string } = {}
	local paths = {}
	for path in files do
		table.insert(paths, path)
	end
	table.sort(paths)
	for _, path in paths do
		local source = files[path]
		local kit = string.match(path, "packages/kits/([%w_%-]+)/shared/")
		if string.match(path, "/ModuleClients%.luau$") then
			local block = string.match(source, "ACTIONS%s*=%s*table%.freeze%((%b{})%)")
				or string.match(source, "ACTIONS%s*=%s*(%b{})")
			if block then
				for owner, inner in string.gmatch(block, "([%a_][%w_]*)%s*=%s*(%b{})") do
					for action in string.gmatch(inner, "([%a_][%w_]*)%s*=") do
						actions[action] = owner
					end
				end
			end
		elseif kit then
			local name, requires = parseDefinition(source)
			if name then
				specs[name] = { kit = kit, requires = requires }
			end
		end
	end
	local manifest: any = { ORDER = {}, SPECS = specs, ACTIONS = actions }
	for _, name in KitModules.ORDER do
		if specs[name] then
			table.insert(manifest.ORDER, name)
		end
	end
	-- kit modules the template doesn't list yet go last, alphabetically
	local extra = {}
	for name in specs do
		if not table.find(manifest.ORDER, name) then
			table.insert(extra, name)
		end
	end
	table.sort(extra)
	for _, name in extra do
		table.insert(manifest.ORDER, name)
	end

	manifest.FOUNDATION = KitModules.FOUNDATION

	function manifest.isFoundation(name: any): boolean
		return type(name) == "string" and table.find(KitModules.FOUNDATION, name) ~= nil
	end

	function manifest.kitFolder(name: string): string?
		local spec = specs[name]
		if spec == nil then
			return nil
		end
		return string.upper(string.sub(spec.kit, 1, 1)) .. string.sub(spec.kit, 2)
	end

	function manifest.isModule(name: any): boolean
		return type(name) == "string" and specs[name] ~= nil
	end

	function manifest.resolve(names: { string }): ({ string }?, { string }?)
		local set: { [string]: boolean } = {}
		local errors: { string } = {}
		for _, n in names do
			if not specs[n] then
				table.insert(errors, `unknown module '{n}'`)
			end
			set[n] = true
		end
		for _, n in names do
			if specs[n] then
				for _, dep in specs[n].requires do
					if not set[dep] then
						table.insert(errors, `{n} requires '{dep}' (add it to GameConfig.modules)`)
					end
				end
			end
		end
		if #errors > 0 then
			return nil, errors
		end
		local order = {}
		for _, n in manifest.ORDER do
			if set[n] then
				table.insert(order, n)
			end
		end
		return order, nil
	end

	return manifest
end

-- fs = @lune/fs
function KitModules.load(fs: any): any
	local files: { [string]: string } = {}
	for _, kit in fs.readDir("packages/kits") do
		local dir = "packages/kits/" .. kit .. "/shared"
		if kit ~= "compat" and fs.isDir("packages/kits/" .. kit) and fs.isDir(dir) then
			for _, entry in fs.readDir(dir) do
				if string.match(entry, "%.luau$") and not string.match(entry, "%.spec%.luau$") then
					files[dir .. "/" .. entry] = fs.readFile(dir .. "/" .. entry)
				end
			end
		end
	end
	return KitModules.parse(files)
end

return KitModules
