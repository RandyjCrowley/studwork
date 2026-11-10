--!strict
--[[
	Server-only settings (Types.ServerConfig). Lives in ServerScriptService, so clients never
	receive it. Passed as Core.start's second argument by Main.server.luau.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local ServerConfig: Types.ServerConfig = {
	admins = {}, -- Roblox user ids allowed to trigger events live; in Studio every player counts
}

return ServerConfig
