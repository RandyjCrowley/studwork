--!strict
--[[
	Server-only settings (ServerConfig, module-api.md §11). Lives in ServerScriptService, so
	clients never receive it. Passed as StudWork.start's second argument by Main.server.luau.
]]

local ServerConfig = {
	admins = {} :: { number }, -- Roblox user ids allowed to trigger events live; in Studio every player counts
	-- Hidden flags (docs/framework/kits/environments.md): the fields of GameConfig.flags, never replicated.
	flags = {} :: { [string]: any },
	-- Open Cloud from a game server (module-api.md §23.7): deny by default. A module may use a secret
	-- only when it, the method and a path pattern are listed here; the secret itself lives in the
	-- experience's secrets store. For the Notifications module (docs/framework/kits/notifications.md):
	-- openCloud = {
	-- 	secrets = {
	-- 		OpenCloudNotifications = { modules = { "Notifications" }, methods = { "POST" }, paths = { "users/*/notifications" } },
	-- 	},
	-- },
}

return ServerConfig
