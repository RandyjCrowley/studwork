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

-- net (step 4b): the module's own generated Blink server module; its events back `actions`
local SURFACES = { "api", "txApi", "extensions", "purchaseOps", "actions", "net" }

-- The Phase 0 kit layout (core-v1.3.0 step 4b-IIa, TEMPORARY until the Phase 1 kit rewrite moves
-- each kit module to ServerScriptService.Modules): the eleven v1.2 services sit in
-- ServerScriptService.Kits.<Kit>, and each kit's ModuleServers.loadServer(ref) returns the
-- module's server part (packages/kits/<kit>/server/ModuleServers.luau).
local function kitLoadServer(ref: any): any
	local kits = game:GetService("ServerScriptService"):FindFirstChild("Kits")
	if kits == nil then
		return nil
	end
	for _, kit in kits:GetChildren() do
		local servers = kit:FindFirstChild("ModuleServers")
		if servers and servers:IsA("ModuleScript") then
			local impl = (require :: any)(servers).loadServer(ref)
			if impl ~= nil then
				return impl
			end
		end
	end
	return nil
end

-- ServerScriptService.Modules.<server>, or one level down in a kit folder
-- (ServerScriptService.Modules.<Kit>.<server>), so a game's Rojo project can map each kit's
-- server/modules folder as a whole; then the Phase 0 kit layout (kitLoadServer).
local function defaultLoadServer(ref: any): any
	local folder = game:GetService("ServerScriptService"):FindFirstChild("Modules")
	if folder == nil then
		return kitLoadServer(ref)
	end
	local part = folder:FindFirstChild(ref.server)
	if part == nil then
		for _, child in folder:GetChildren() do
			if child:IsA("Folder") then
				part = child:FindFirstChild(ref.server)
				if part then
					break
				end
			end
		end
	end
	if part == nil or not part:IsA("ModuleScript") then
		return kitLoadServer(ref)
	end
	return (require :: any)(part)
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
	local find = loadServer or defaultLoadServer
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
