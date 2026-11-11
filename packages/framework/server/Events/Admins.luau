--!strict
--[[
	Admin check for live events (L5). Pure.

	isAdmin(userId, isStudio, serverAdmins, legacyAdmins):
	  - Studio: everyone is admin.
	  - otherwise userId must be in ServerConfig.admins (server-only, Core.start's 2nd argument)
	    or in the deprecated GameConfig.admins (replicated to clients; still honoured).
	usesLegacy(legacyAdmins): true when GameConfig.admins is set (Events warns once).
]]

local Admins = {}

local function contains(list: { number }?, userId: number): boolean
	return type(list) == "table" and table.find(list, userId) ~= nil
end

function Admins.isAdmin(
	userId: number,
	isStudio: boolean,
	serverAdmins: { number }?,
	legacyAdmins: { number }?
): boolean
	if isStudio then
		return true
	end
	return contains(serverAdmins, userId) or contains(legacyAdmins, userId)
end

function Admins.usesLegacy(legacyAdmins: { number }?): boolean
	return type(legacyAdmins) == "table" and next(legacyAdmins) ~= nil
end

Admins.LEGACY_WARNING = "[Core.Events] GameConfig.admins is deprecated (it replicates to every client): "
	.. "move the ids to ServerConfig.admins and call Core.start(Config, ServerConfig) on the server"

return Admins
