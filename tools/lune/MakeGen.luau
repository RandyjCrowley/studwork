--!strict
--[[
	tools/lune/MakeGen: the StudWork generators behind tools/make-module, tools/make-migration and
	tools/make-screen (v1.3.0). No requires: the Lune `fs` is passed in, so
	the self-test (MakeGen.spec.luau) generates into a scratch folder and cleans up.

	Names
	  isModuleName(s)        PascalCase, <= 48 chars (defineModule's rule)
	  kebab("SessionBoard")  -> "session-board"   (the module's folder)
	  camel("SessionBoard")  -> "sessionBoard"    (the default data.key)

	make-module (module-api.md §1 anatomy)
	  moduleFiles(name, dir, opts?) -> { [relativePath] = source }
	      module.luau (definition: config with defaults, a save section that replicates, server +
	      client names), server/init.luau (init/start/api through ctx only), client/init.luau,
	      tests/<Name>.spec.luau (a passing harness test), README.md; opts.net (--net): net.blink,
	      the module's own messages (RemoteScope "STUDWORK_<NAME>", ServerOutput server/Net.luau,
	      ClientOutput client/Net.luau: the v1.3.1 convention). No migrations/ folder yet:
	      tools/make-migration creates it with the first migration (an empty or README-only folder
	      would be read as migrations)
	  writeModule(fs, name, dir, opts?) -> (files?, error?) refuses an existing folder
	  addToProject(project, name, rel) -> project           maps ReplicatedStorage.Modules.<Name>
	      (module, client, migrations) and ServerScriptService.Modules.<Name> (server) in a decoded
	      default.project.json; `rel` = the module folder relative to the project file
	  configLine(name) -> string                             the GameConfig.modules line to add
	                                                         (after `local GameModules =
	                                                         ReplicatedStorage:WaitForChild("Modules")`)

	make-migration (module-api.md §6)
	  dataVersion(moduleSource) -> number?                   data.version in module.luau
	  nextMigration(moduleSource, existing, label) -> (plan?, error?)
	      plan = { version, file, source (the migration), spec (a test stub), module (module.luau
	      with data.version bumped and `migrations = script.Parent.migrations` declared) }
	  writeMigration(fs, dir, label) -> (plan?, error?)

	make-screen (module-api.md §13: UI.registerScreen / UI.open)
	  screenSource(name) -> string                           a React screen built from UI kit parts
	  registrySource() -> string                             src/client/Screens/init.luau
	  hookMain(mainSource) -> (source?, changed, error?)     calls Screens.registerAll() right after
	                                                         StudWork.start(Config)
	  writeScreen(fs, gameDir, name) -> (written?, error?)
]]

local MakeGen = {}

local FRAMEWORK_RANGE = "^1.3.0"

function MakeGen.isModuleName(s: any): boolean
	return type(s) == "string" and #s <= 48 and string.match(s, "^%u[%w]*$") ~= nil
end

function MakeGen.kebab(name: string): string
	local out = string.gsub(name, "(%l)(%u)", "%1-%2")
	out = string.gsub(out, "(%u)(%u%l)", "%1-%2")
	return string.lower(out)
end

function MakeGen.camel(name: string): string
	return string.lower(string.sub(name, 1, 1)) .. string.sub(name, 2)
end

-- The generators' templates are files in the core's templates/ folder (v1.4.0: templates/module/,
-- templates/migration/, templates/screen/; `{{key}}` placeholders), read once on first use. The
-- reader is Lune's fs (a Lune script, or a spec through the testkit, which reaches Lune's require
-- through its environment) unless MakeGen.setTemplateReader(fn(relativePath) -> string) is set.
-- The core folder comes from STUDWORK_CORE_DIR (tools/lune/Roots.luau): in a games repo,
-- roblox-core/templates.
local templateCache: { [string]: string } = {}
local templateReader: ((string) -> string)? = nil

local function luneModule(name: string): any
	local ok, m = pcall(require :: any, name)
	if ok and type(m) == "table" then
		return m
	end
	local mt = getmetatable(getfenv(1) :: any)
	local index = mt and (mt :: any).__index
	if type(index) == "table" and type(index.require) == "function" then
		return index.require(name)
	end
	error("MakeGen: can't load " .. name .. " (pass MakeGen.setTemplateReader)")
end

function MakeGen.setTemplateReader(reader: ((string) -> string)?)
	templateReader = reader
	table.clear(templateCache)
end

local function template(rel: string): string
	local cached = templateCache[rel]
	if cached then
		return cached
	end
	local text
	if templateReader then
		text = templateReader(rel)
	else
		local fs = luneModule("@lune/fs")
		local core = luneModule("@lune/process").env.STUDWORK_CORE_DIR
		local prefix = if core == nil
				or core == ""
				or core == "."
			then ""
			else string.gsub(core, "/+$", "") .. "/"
		text = fs.readFile(prefix .. "templates/" .. rel)
	end
	templateCache[rel] = text
	return text
end

local function fill(template: string, vars: { [string]: string }): string
	return (
		string.gsub(template, "{{(%w+)}}", function(key: string): string
			local value = vars[key]
			assert(value ~= nil, "MakeGen: no value for {{" .. key .. "}}")
			return value
		end)
	)
end

-- MODULE_TEMPLATE: templates/module/module.luau.tmpl

-- SERVER_TEMPLATE: templates/module/server/init.luau.tmpl

-- CLIENT_TEMPLATE: templates/module/client/init.luau.tmpl

-- net.blink (tools/make-module --net): this module's own client <-> server messages (module-api.md
-- §1, §9; v1.3.1 R19 convention). tools/net compiles it into server/Net.luau and
-- client/Net.luau; the framework binds each as the part's `net` (module-api.md §19.9), so a server
-- action `{{camel}}Ping = { handler = ... }` / client `actions = { "ping" }` fires the event.
-- NET_TEMPLATE: templates/module/net.blink.tmpl

-- SPEC_TEMPLATE: templates/module/tests/Name.spec.luau.tmpl

-- README_TEMPLATE: templates/module/README.md.tmpl

function MakeGen.moduleFiles(name: string, dir: string, opts: { net: boolean? }?): { [string]: string }
	local vars = {
		Name = name,
		UPPER = string.upper(name),
		camel = MakeGen.camel(name),
		key = MakeGen.camel(name),
		dir = dir,
		range = FRAMEWORK_RANGE,
	}
	local files = {
		["module.luau"] = fill(template("module/module.luau.tmpl"), vars),
		["server/init.luau"] = fill(template("module/server/init.luau.tmpl"), vars),
		["client/init.luau"] = fill(template("module/client/init.luau.tmpl"), vars),
		[`tests/{name}.spec.luau`] = fill(template("module/tests/Name.spec.luau.tmpl"), vars),
		["README.md"] = fill(template("module/README.md.tmpl"), vars),
	}
	if opts and opts.net then
		files["net.blink"] = fill(template("module/net.blink.tmpl"), vars)
	end
	return files
end

local function writeFiles(fs: any, dir: string, files: { [string]: string })
	local paths = {}
	for rel in files do
		table.insert(paths, rel)
	end
	table.sort(paths)
	for _, rel in paths do
		local full = dir .. "/" .. rel
		local parent = string.match(full, "^(.*)/[^/]+$")
		if parent then
			fs.writeDir(parent)
		end
		fs.writeFile(full, files[rel])
	end
end

function MakeGen.writeModule(
	fs: any,
	name: string,
	dir: string,
	opts: { net: boolean? }?
): ({ [string]: string }?, string?)
	if not MakeGen.isModuleName(name) then
		return nil,
			`bad module name '{name}': PascalCase letters and digits, starting upper-case, <= 48 chars`
	end
	if fs.isDir(dir) or fs.isFile(dir) then
		return nil, dir .. " already exists"
	end
	local files = MakeGen.moduleFiles(name, dir, opts)
	writeFiles(fs, dir, files)
	return files, nil
end

function MakeGen.addToProject(project: any, name: string, rel: string, hasMigrations: boolean?): any
	local tree = project.tree
	tree.ReplicatedStorage = tree.ReplicatedStorage or {}
	local rs = tree.ReplicatedStorage
	rs.Modules = rs.Modules or { ["$className"] = "Folder" }
	rs.Modules[name] = {
		["$className"] = "Folder",
		module = { ["$path"] = rel .. "/module.luau" },
		client = { ["$path"] = rel .. "/client" },
	}
	if hasMigrations then
		rs.Modules[name].migrations = { ["$path"] = rel .. "/migrations" }
	end
	tree.ServerScriptService = tree.ServerScriptService or {}
	local sss = tree.ServerScriptService
	sss.Modules = sss.Modules or { ["$className"] = "Folder" }
	sss.Modules[name] = { ["$path"] = rel .. "/server" }
	return project
end

function MakeGen.configLine(name: string): string
	return `require(GameModules:WaitForChild("{name}"):WaitForChild("module")),`
end

-- make-migration ------------------------------------------------------------------------------

local function dataBlock(source: string): (number?, number?)
	return string.find(source, "\n\tdata%s*=%s*%b{}")
end

function MakeGen.dataVersion(source: string): number?
	local s, e = dataBlock(source)
	if s == nil then
		return nil
	end
	local block = string.sub(source, s :: number, e :: number)
	local v = string.match(block, "\n\t\tversion%s*=%s*(%d+)")
	return if v then tonumber(v) else nil
end

-- MIGRATION_TEMPLATE: templates/migration/migration.luau.tmpl

-- MIGRATION_SPEC_TEMPLATE: templates/migration/Migration.spec.luau.tmpl

local function moduleNameOf(source: string): string?
	local body = string.match(source, "defineModule%(%s*(%b{})")
	return body and string.match(body, '\n\tname%s*=%s*"([%w_]+)"')
end

local function dataKeyOf(source: string): string?
	local s, e = dataBlock(source)
	if s == nil then
		return nil
	end
	return string.match(string.sub(source, s :: number, e :: number), '\n\t\tkey%s*=%s*"([^"]+)"')
end

function MakeGen.nextMigration(
	source: string,
	existing: { string },
	label: string?,
	dir: string?
): (any?, string?)
	local name = moduleNameOf(source)
	if name == nil then
		return nil, "module.luau: no StudWork.defineModule({ name = ... })"
	end
	local version = MakeGen.dataVersion(source)
	if version == nil then
		return nil,
			`{name}: module.luau has no data = \{ version = N, ... \} block (no save section to migrate)`
	end
	local to = version + 1
	for _, file in existing do
		local n = tonumber(string.match(file, "^(%d+)_"))
		if n and n >= to then
			return nil,
				`{name}: migrations/{file} is already for version {n}, but data.version is {version}; bump data.version first`
		end
	end
	local slug = string.gsub(string.lower(label or "migration"), "[^%w]+", "_")
	slug = string.gsub(slug, "^_+", "")
	slug = string.gsub(slug, "_+$", "")
	if slug == "" then
		slug = "migration"
	end
	local file = string.format("%03d_%s", to, slug)
	local vars = {
		Name = name,
		key = dataKeyOf(source) or "?",
		from = tostring(version),
		to = tostring(to),
		file = file,
		dir = dir or ".",
	}
	-- bump data.version and declare the migrations folder (once)
	local s, e = dataBlock(source)
	local block = string.sub(source, s :: number, e :: number)
	local newBlock = string.gsub(block, "(\n\t\tversion%s*=%s*)%d+", "%1" .. to, 1)
	if not string.find(newBlock, "\n\t\tmigrations%s*=") then
		newBlock = string.gsub(
			newBlock,
			"(\n\t\tversion%s*=%s*%d+,)",
			"%1\n\t\tmigrations = script.Parent.migrations,",
			1
		)
	end
	local module = string.sub(source, 1, (s :: number) - 1)
		.. newBlock
		.. string.sub(source, (e :: number) + 1)
	return {
		version = to,
		file = file,
		source = fill(template("migration/migration.luau.tmpl"), vars),
		spec = fill(template("migration/Migration.spec.luau.tmpl"), vars),
		module = module,
		name = name,
	},
		nil
end

function MakeGen.writeMigration(fs: any, dir: string, label: string?): (any?, string?)
	local modulePath = dir .. "/module.luau"
	if not fs.isFile(modulePath) then
		return nil, "no module.luau in " .. dir
	end
	local existing = {}
	if fs.isDir(dir .. "/migrations") then
		for _, entry in fs.readDir(dir .. "/migrations") do
			if string.match(entry, "%.luau$") then
				table.insert(existing, entry)
			end
		end
	end
	local plan, err = MakeGen.nextMigration(fs.readFile(modulePath), existing, label, dir)
	if plan == nil then
		return nil, err
	end
	fs.writeDir(dir .. "/migrations")
	fs.writeDir(dir .. "/tests")
	fs.writeFile(`{dir}/migrations/{plan.file}.luau`, plan.source)
	fs.writeFile(`{dir}/tests/Migration{string.format("%03d", plan.version)}.spec.luau`, plan.spec)
	fs.writeFile(modulePath, plan.module)
	return plan, nil
end

-- make-screen -----------------------------------------------------------------------------------

-- SCREEN_TEMPLATE: templates/screen/Screen.luau.tmpl

-- REGISTRY_TEMPLATE: templates/screen/Screens.init.luau.tmpl

local HOOK_LINE = 'require(script.Parent:WaitForChild("Screens")).registerAll()'

function MakeGen.screenSource(name: string): string
	local title = string.gsub(name, "(%l)(%u)", "%1 %2")
	return fill(template("screen/Screen.luau.tmpl"), { Name = name, title = title })
end

function MakeGen.registrySource(): string
	return template("screen/Screens.init.luau.tmpl")
end

function MakeGen.hookMain(source: string): (string?, boolean, string?)
	if string.find(source, HOOK_LINE, 1, true) then
		return source, false, nil
	end
	local s, e = string.find(source, "\nStudWork%.start%(Config%)\n")
	if s == nil then
		return nil,
			false,
			"Main.client.luau has no `StudWork.start(Config)` line to register the screens after"
	end
	local line = "-- the game's screens (src/client/Screens, tools/make-screen)\n" .. HOOK_LINE .. "\n"
	return string.sub(source, 1, e :: number) .. line .. string.sub(source, (e :: number) + 1), true, nil
end

function MakeGen.writeScreen(fs: any, gameDir: string, name: string): ({ string }?, string?)
	if not MakeGen.isModuleName(name) then
		return nil, `bad screen name '{name}': PascalCase letters and digits, starting upper-case`
	end
	local clientDir = gameDir .. "/src/client"
	local mainPath = clientDir .. "/Main.client.luau"
	if not fs.isFile(mainPath) then
		return nil, "no " .. mainPath
	end
	local screenPath = `{clientDir}/Screens/{name}.luau`
	if fs.isFile(screenPath) then
		return nil, screenPath .. " already exists"
	end
	local main, changed, err = MakeGen.hookMain(fs.readFile(mainPath))
	if main == nil then
		return nil, err
	end
	local written = {}
	fs.writeDir(clientDir .. "/Screens")
	local registryPath = clientDir .. "/Screens/init.luau"
	if not fs.isFile(registryPath) then
		fs.writeFile(registryPath, template("screen/Screens.init.luau.tmpl"))
		table.insert(written, registryPath)
	end
	fs.writeFile(screenPath, MakeGen.screenSource(name))
	table.insert(written, screenPath)
	if changed then
		fs.writeFile(mainPath, main :: string)
		table.insert(written, mainPath)
	end
	return written, nil
end

return MakeGen
