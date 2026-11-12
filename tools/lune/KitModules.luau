--!strict
--[[
	tools/lune/KitModules: the kit module manifest for tools (v1.3.0), read from
	the kit module DEFINITIONS (v1.3.1 R19, one folder per module:
	packages/kits/<kit>/<Module>/module.luau, defineModule) instead of the deleted v1.2 module
	manifest. Pure helpers; the file reading is in KitModules.load(fs) (module folders found by
	tools/lune/ModuleDiscovery.luau, the same discovery as the testkit, the sim and sync-projects).

	KitModules.parse(files)  files = { [path] = source } -> manifest
	                         (packages/kits/<kit>/<Module>/module.luau and .../client/init.luau)
	KitModules.load(fs)      reads every kit module folder -> manifest
	manifest = {
	  ORDER     { string }                       the template's boot order (GameConfig.modules)
	  SPECS     { [name] = { kit, requires } }   requires = hard deps (defineModule dependsOn)
	  ACTIONS   { [action] = owner module }      client actions (<Module>/client/init.luau `actions`)
	  FOUNDATION, isFoundation(name)             framework services (never listed)
	  kitFolder(name) -> "Collection" | ...      the kit a module ships in (packages/kits/<kit>)
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
	"Leaderboards",
	"Badges",
	"Notifications",
	"Friends",
	"Mail",
	"TextFilter",
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
		for quoted in string.gmatch(deps, 'WaitForChild%("([%w_]+)"%):WaitForChild%("module"%)%)') do
			table.insert(requires, quoted)
		end
		if #requires == 0 then
			for quoted in string.gmatch(deps, 'WaitForChild%("([%w_]+)"%)%)') do
				table.insert(requires, quoted)
			end
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
		local kit, folder = string.match(path, "packages/kits/([%w_%-]+)/([%w_]+)/module%.luau$")
		local ckit, cfolder = string.match(path, "packages/kits/([%w_%-]+)/([%w_]+)/client/init%.luau$")
		if kit then
			local name, requires = parseDefinition(source)
			if name then
				specs[name] = { kit = kit, folder = folder, requires = requires }
			end
		elseif ckit then
			-- `actions = { name = "Event", ... }` or `actions = { "name", ... }` (module-api.md §9)
			local block = string.match(source, "actions%s*=%s*(%b{})")
			if block then
				local inner = string.sub(block, 2, -2)
				for action in string.gmatch(inner, "([%a_][%w_]*)%s*=") do
					actions[action] = cfolder
				end
				local first = string.match(inner, '^%s*"([%a_][%w_]*)"') -- gmatch can't anchor '^'
				if first then
					actions[first] = cfolder
				end
				for action in string.gmatch(inner, ',%s*"([%a_][%w_]*)"') do
					actions[action] = cfolder
				end
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

-- fs = @lune/fs; discovery = tools/lune/ModuleDiscovery (Lune scripts may omit it; a spec loaded
-- through the testkit passes require("tools/lune/ModuleDiscovery.luau"))
-- coreDir: the core's folder (tools/lune/Roots.luau); default Roots.CORE when Roots loads.
function KitModules.load(fs: any, discovery: any?, coreDir: string?): any
	local ModuleDiscovery = discovery or (require :: any)("./ModuleDiscovery")
	if coreDir == nil then
		local ok, Roots = pcall(require :: any, "./Roots")
		coreDir = if ok and type(Roots) == "table" then Roots.CORE else nil
	end
	local files: { [string]: string } = {}
	for _, entry in ModuleDiscovery.discover(fs, coreDir) do
		if entry.kit ~= nil then
			files[entry.module] = fs.readFile(entry.module)
			local client = entry.dir .. "/client/init.luau"
			if fs.isFile(client) then
				files[client] = fs.readFile(client)
			end
		end
	end
	return KitModules.parse(files)
end

return KitModules
