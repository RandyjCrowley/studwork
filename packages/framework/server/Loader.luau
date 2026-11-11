--!strict
--[[
	Server loader (module-api.md §3 step 1): resolves GameConfig.modules (shared Resolve: refs only,
	hard deps listed, unique names + data keys, framework range, topo order with list-order ties,
	named cycles) and finds each module's server part BY NAME (ref.server, default ref.name) under
	ServerScriptService.Modules, or through an injected `loadServer(ref)` (tests, custom layouts).

	The save-section OWNER check (H5) needs each player's `_framework._owners`, so it runs on every
	profile load in Data (a mismatch is a load error: the player is kicked and nothing is saved),
	not here; this file checks what can be checked once per server: data.key uniqueness among
	enabled modules.

	Loader.load(gameConfig, frameworkVersion, loadServer?) -> (order, impls)   errors list everything
]]

local Shared = require(script.Parent.Shared)
local requireShared = require :: any -- see Shared.luau
local Resolve = requireShared(Shared.Resolve)

local Loader = {}

-- net (v1.3.0): the module's own generated Blink server module; its events back `actions`
local SURFACES = { "api", "txApi", "extensions", "purchaseOps", "actions", "net" }

-- The live lookup (module-api.md §19.9, added in core-v1.3.1: R19, one folder per module):
-- ServerScriptService.Modules[ref.server], a direct child and nothing else (Rojo maps every
-- module folder's server/ there). Then:
--   * a required table with a `new` function and no `init`/`start` is a part FACTORY: new() builds
--     a fresh part, so two runtimes in one process (tests, the sim) never share module state;
--   * a part without a `net` field gets the server part instance's `Net` ModuleScript child (the
--     module's generated Blink server module, from its net.blink) as `net`; it backs `actions`.
-- nil when the module has no server part (a definition-only module is valid).
-- `modulesFolder` (tests): the folder to look in instead of ServerScriptService.Modules.
-- `opts.bindNet == false` (the Lune testkit and the sim: no Blink wire there, and a generated Net
-- module needs the engine): don't bind the Net child.
function Loader.defaultLoadServer(ref: any, modulesFolder: any?, opts: { bindNet: boolean? }?): any
	local folder = modulesFolder or game:GetService("ServerScriptService"):FindFirstChild("Modules")
	if folder == nil then
		return nil
	end
	local instance = folder:FindFirstChild(ref.server)
	if instance == nil or not instance:IsA("ModuleScript") then
		return nil
	end
	local part = (require :: any)(instance)
	if type(part) ~= "table" then
		return part -- Loader.load reports the type
	end
	if type(part.new) == "function" and part.init == nil and part.start == nil then
		part = part.new()
		if type(part) ~= "table" then
			error(`{ref.server}.new() must return the server part table, got {type(part)}`, 0)
		end
	end
	if part.net == nil and not (opts and opts.bindNet == false) then
		local net = instance:FindFirstChild("Net")
		if net ~= nil and net:IsA("ModuleScript") then
			if table.isfrozen(part) then
				part = table.clone(part)
			end
			part.net = (require :: any)(net)
		end
	end
	return part
end

function Loader.load(
	gameConfig: any,
	frameworkVersion: string,
	loadServer: ((ref: any) -> any)?
): ({ any }, { [any]: any })
	if type(gameConfig) ~= "table" then
		error("GameConfig must be a table", 0)
	end
	local order, errors = Resolve.resolve(gameConfig.modules, frameworkVersion)
	if order == nil then
		error("invalid GameConfig.modules:\n  - " .. table.concat(errors :: { string }, "\n  - "), 0)
	end
	local find = loadServer or Loader.defaultLoadServer
	local impls: { [any]: any } = {}
	local implErrors: { string } = {}
	for _, ref in order do
		local ok, impl = pcall(find, ref)
		if not ok then
			table.insert(
				implErrors,
				`{ref.name}: loading server part '{ref.server}' failed: {tostring(impl)}`
			)
			continue
		end
		if impl == nil then
			impl = {} -- a module with only a definition (data/config/theme) is valid
		end
		if type(impl) ~= "table" then
			table.insert(implErrors, `{ref.name}: server part must return a table, got {type(impl)}`)
			continue
		end
		for _, fname in { "init", "start" } do
			if impl[fname] ~= nil and type(impl[fname]) ~= "function" then
				table.insert(implErrors, `{ref.name}: server.{fname} must be a function(ctx)`)
			end
		end
		for _, s in SURFACES do
			if impl[s] ~= nil and type(impl[s]) ~= "table" then
				table.insert(implErrors, `{ref.name}: server.{s} must be a table`)
			end
		end
		impls[ref] = impl
	end
	if #implErrors > 0 then
		error("invalid module server parts:\n  - " .. table.concat(implErrors, "\n  - "), 0)
	end
	return order :: { any }, impls
end

return Loader
