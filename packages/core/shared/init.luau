--!strict
--[[
	Core facade: `local Core = require(ReplicatedStorage.Core)`.

	Call Core.start(GameConfig) once on the client and Core.start(GameConfig, ServerConfig) once
	on the server. Server namespaces (Economy, Inventory, ...) exist only on the server;
	Core.Client exists only on the client. Indexing the wrong side errors.

	The public surface is typed by Types.CoreAPI and is FROZEN (additive only). See CLAUDE.md.
	M7: every namespace is a frozen table holding exactly the functions listed in Modules.API
	(the Types.<Name>API fields), so init/start and private helpers are not reachable, and a
	second Core.start errors. Functions of an optional module that is not in GameConfig.modules
	error with "<Name> is not enabled in GameConfig.modules"; any call before Core.start errors.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ConfigValidate = require(script.ConfigValidate)
local Modules = require(script.Modules)
local Signals = require(script.Signals)
local Types = require(script.Types)

local IS_SERVER = RunService:IsServer()

local started = false
local activeConfig: Types.GameConfig? = nil
local enabled: { [string]: boolean } = {}
local bootError: string? = nil -- set when Core.start threw part-way (review N7): every call errors

local Core = {}
Core.version = "1.2.0"
Core.Signals = Signals.new()

local function guarded(namespace: string, fnName: string, impl: (...any) -> ...any): (...any) -> ...any
	local isModule = Modules.isModule(namespace)
	return function(...: any): ...any
		if not started then
			error(`[Core] Core.{namespace}.{fnName} called before Core.start`, 2)
		end
		if bootError ~= nil then
			error(`[Core] Core.{namespace}.{fnName}: Core.start failed: {bootError}`, 2)
		end
		if isModule and not enabled[namespace] then
			error("[Core] " .. Modules.notEnabledMessage(namespace), 2)
		end
		return impl(...)
	end
end

-- Frozen public table for one server namespace: only the names in Modules.API. A service may
-- give the facade a different implementation of a function in `service.facade` (v1.2: Data
-- returns read-only views in Studio, N8); core services keep calling the service directly.
local function publicTable(namespace: string, service: { [string]: any }): { [string]: any }
	local api: { [string]: any } = {}
	local overrides: { [string]: any } = if type(service.facade) == "table" then service.facade else {}
	for _, fnName in Modules.API[namespace] do
		local impl = overrides[fnName] or service[fnName]
		assert(
			type(impl) == "function",
			`[Core] contract mismatch: {namespace}.{fnName} is listed in Modules.API but not implemented`
		)
		api[fnName] = guarded(namespace, fnName, impl)
	end
	return table.freeze(api)
end

local SERVER_ONLY: { [string]: boolean } = {}
for namespace in Modules.API do
	SERVER_ONLY[namespace] = true
end

local sideModule: any = nil
if IS_SERVER then
	local ServerScriptService = game:GetService("ServerScriptService")
	sideModule = require(ServerScriptService:WaitForChild("CoreServer"))
	for namespace in Modules.API do
		(Core :: any)[namespace] = publicTable(namespace, sideModule.services[namespace])
	end
else
	sideModule = require(ReplicatedStorage:WaitForChild("CoreClient"))
	Core.Client = sideModule.api
end

function Core.start(gameConfig: Types.GameConfig, serverConfig: Types.ServerConfig?)
	if started then
		error("[Core] Core.start was already called (call it once per side)", 2)
	end
	local config = ConfigValidate.assertValid(gameConfig)
	if not IS_SERVER and serverConfig ~= nil then
		error("[Core] ServerConfig is server-only: call Core.start(Config) on the client", 2)
	end
	local order = Modules.resolve(config.modules) :: { string }
	for _, name in order do
		enabled[name] = true
	end
	started = true
	activeConfig = config
	local ok, err = pcall(sideModule.start, Core, config, serverConfig or {}, order)
	if not ok then
		local message = tostring(err)
		bootError = message
		error("[Core] Core.start failed (core is unusable until the server restarts): " .. message, 2)
	end
end

function Core.isStarted(): boolean
	return started and bootError == nil
end

function Core.isEnabled(moduleName: Types.ModuleName): boolean
	return enabled[moduleName] == true
end

function Core.config(): Types.GameConfig
	assert(activeConfig, "[Core] Core.config() called before Core.start")
	return activeConfig :: Types.GameConfig
end

setmetatable(Core, {
	__index = function(_, key)
		if SERVER_ONLY[key] then
			error("[Core] Core." .. tostring(key) .. " is server-only", 2)
		elseif key == "Client" then
			error("[Core] Core.Client is client-only", 2)
		end
		error("[Core] Core." .. tostring(key) .. " does not exist", 2)
	end,
})
table.freeze(Core)

return (Core :: any) :: Types.CoreAPI
