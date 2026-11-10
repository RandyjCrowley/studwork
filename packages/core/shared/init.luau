--!strict
--[[
	Core facade: `local Core = require(ReplicatedStorage.Core)`.

	Call Core.start(GameConfig) once on the server (from the game's server script) and once on
	the client (from the game's client script). Server namespaces (Economy, Inventory, ...) exist
	only on the server; Core.Client exists only on the client. Indexing the wrong side errors.

	The public surface is typed by Types.CoreAPI and is FROZEN (additive only). See CLAUDE.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ConfigValidate = require(script.ConfigValidate)
local Signals = require(script.Signals)
local Types = require(script.Types)

local IS_SERVER = RunService:IsServer()

local SERVER_ONLY = {
	Items = true,
	Rarity = true,
	Economy = true,
	Inventory = true,
	Plot = true,
	Rebirth = true,
	Upgrades = true,
	Offline = true,
	Streak = true,
	Friends = true,
	Events = true,
	Shop = true,
	Policy = true,
	Data = true,
	Mail = true,
	Analytics = true,
}

local started = false
local activeConfig: Types.GameConfig? = nil

local Core = {}
Core.version = "0.1.0"
Core.Signals = Signals.new()

local sideModule: any = nil
if IS_SERVER then
	local ServerScriptService = game:GetService("ServerScriptService")
	sideModule = require(ServerScriptService:WaitForChild("CoreServer"))
	for name in SERVER_ONLY do
		(Core :: any)[name] = sideModule.services[name]
	end
else
	sideModule = require(ReplicatedStorage:WaitForChild("CoreClient"))
	Core.Client = sideModule.api
end

function Core.start(gameConfig: Types.GameConfig)
	assert(not started, "[Core] Core.start was already called")
	local config = ConfigValidate.assertValid(gameConfig)
	started = true
	activeConfig = config
	sideModule.start(Core, config)
end

function Core.isStarted(): boolean
	return started
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

return (Core :: any) :: Types.CoreAPI
