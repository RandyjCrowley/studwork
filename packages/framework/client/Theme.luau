--!strict
--[[
	The client's resolved theme (module-api.md §13): the runtime's merged theme (framework-default
	preset -> enabled modules' `theme` -> GameConfig.theme, merged by Framework/shared/Theme during
	client boot step 2), or the framework-default preset when no v1.3 runtime booted (the v1.2
	Core facade path). Read by Hud and Feedback; Hud.init pushes it into UI.Theme.

	ClientTheme.current() -> frozen resolved theme
	ClientTheme.shared     Framework/shared/Theme (pure helpers: tier, tierOrder, sound)
]]

local Boot = require(script.Parent.Boot)

local SharedTheme = (require :: any)(Boot.shared:WaitForChild("Theme"))

local ClientTheme = {}

ClientTheme.shared = SharedTheme

function ClientTheme.current(): any
	local rt = Boot.runtime()
	if type(rt) == "table" and rt.side == "client" and type(rt.theme) == "table" then
		return rt.theme
	end
	return SharedTheme.DEFAULT
end

-- GameConfig.client.hud (nil when no v1.3 runtime booted).
function ClientTheme.clientHud(): any
	local rt = Boot.runtime()
	local gc = if type(rt) == "table" and rt.side == "client" then rt.gameConfig else nil
	local client = if type(gc) == "table" then gc.client else nil
	return if type(client) == "table" then client.hud else nil
end

return ClientTheme
