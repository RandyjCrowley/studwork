--!strict
--[[
	Server-only settings (ServerConfig, module-api.md §11). Lives in ServerScriptService, so
	clients never receive it. Passed as StudWork.start's second argument by Main.server.luau.
]]

local ServerConfig = {
	admins = {} :: { number }, -- Roblox user ids allowed to trigger events live; in Studio every player counts
	-- A hidden flag (same fields as GameConfig.flags; never replicated; docs/framework/kits/environments.md)
	flags = {
		hiddenPricing = { default = true, description = "server-side pricing experiment" },
	} :: { [string]: any },
	-- Open Cloud allow-list (module-api.md §23.7): the Notifications module may POST user
	-- notifications with the secret named OpenCloudNotifications, and nothing else.
	openCloud = {
		secrets = {
			OpenCloudNotifications = {
				modules = { "Notifications" },
				methods = { "POST" },
				paths = { "users/*/notifications" },
			},
		},
	},
}

return ServerConfig
