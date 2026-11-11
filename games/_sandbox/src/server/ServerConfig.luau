--!strict
--[[
	Server-only settings (ServerConfig, module-api.md §11). Lives in ServerScriptService, so
	clients never receive it. Passed as StudWork.start's second argument by Main.server.luau.
]]

local ServerConfig = {
	admins = {} :: { number }, -- Roblox user ids allowed to trigger events live; in Studio every player counts
}

return ServerConfig
