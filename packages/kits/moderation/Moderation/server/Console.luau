--!strict
--[[
	Moderation console commands (design §4 "Console", Addendum C: server-only). Typed with the module
	prefix: `moderation ban <userId> [seconds|-1] [displayKey]`, `unban <userId>`, `kick <userId> [key]`,
	`serverban <userId> [seconds]`, `mute <userId> [seconds] [key]`, `unmute <userId>`,
	`warn <userId> <key>`, `punish <userId> <offense>`, `history <userId>`, `audit [userId]`.
	The framework's console runs a command without a player, so each one acts as by = "console"
	(trusted, audited as such). A non-nil player (never from the framework console) acts as staff.
]]

local Console = {}

local function by(player: any): any
	if typeof(player) == "Instance" then
		return player
	end
	return "console"
end

local function id(v: any): number?
	local n = tonumber(v)
	if n == nil or n < 1 or n % 1 ~= 0 then
		return nil
	end
	return n
end

local function reply(ok: boolean, status: any): string
	return (if ok then "ok: " else "refused: ") .. tostring(status)
end

function Console.register(console: any, api: any)
	console.register("ban", function(player: any, userId: string?, seconds: string?, key: string?): string
		local uid = id(userId)
		if uid == nil then
			return "usage: moderation ban <userId> [seconds|-1] [displayKey]"
		end
		local s = if seconds ~= nil then tonumber(seconds) else nil
		return reply(api.ban(uid, { by = by(player), seconds = s, displayKey = key }))
	end, "moderation ban <userId> [seconds|-1] [displayKey]")

	console.register("unban", function(player: any, userId: string?): string
		local uid = id(userId)
		if uid == nil then
			return "usage: moderation unban <userId>"
		end
		return reply(api.unban(uid, { by = by(player) }))
	end, "moderation unban <userId>")

	console.register("kick", function(player: any, userId: string?, key: string?): string
		local uid = id(userId)
		if uid == nil then
			return "usage: moderation kick <userId> [key]"
		end
		return reply(api.kick(uid, { by = by(player), key = key }))
	end, "moderation kick <userId> [key]")

	console.register("serverban", function(player: any, userId: string?, seconds: string?): string
		local uid = id(userId)
		if uid == nil then
			return "usage: moderation serverban <userId> [seconds]"
		end
		local s = if seconds ~= nil then tonumber(seconds) else nil
		return reply(api.serverBan(uid, { by = by(player), seconds = s }))
	end, "moderation serverban <userId> [seconds]")

	console.register("mute", function(player: any, userId: string?, seconds: string?, key: string?): string
		local uid = id(userId)
		if uid == nil then
			return "usage: moderation mute <userId> [seconds] [key]"
		end
		local s = if seconds ~= nil then tonumber(seconds) else nil
		return reply(api.mute(uid, { by = by(player), seconds = s, key = key }))
	end, "moderation mute <userId> [seconds] [key]")

	console.register("unmute", function(player: any, userId: string?): string
		local uid = id(userId)
		if uid == nil then
			return "usage: moderation unmute <userId>"
		end
		return reply(api.unmute(uid, { by = by(player) }))
	end, "moderation unmute <userId>")

	console.register("warn", function(player: any, userId: string?, key: string?): string
		local uid = id(userId)
		if uid == nil or key == nil then
			return "usage: moderation warn <userId> <key>"
		end
		return reply(api.warn(uid, { by = by(player), key = key }))
	end, "moderation warn <userId> <key>")

	console.register("punish", function(player: any, userId: string?, offense: string?): string
		local uid = id(userId)
		if uid == nil or offense == nil then
			return "usage: moderation punish <userId> <offense>"
		end
		local ok, step, status = api.punish(uid, offense, { by = by(player) })
		return reply(ok, if ok then `{step} {tostring(status)}` else step)
	end, "moderation punish <userId> <offense>")

	console.register("history", function(player: any, userId: string?): string
		local uid = id(userId)
		if uid == nil then
			return "usage: moderation history <userId>"
		end
		local ok, entries = api.history(uid, { by = by(player) })
		if not ok then
			return reply(false, entries)
		end
		local lines = {}
		for _, e in entries do
			table.insert(lines, `{if e.ban then "ban" else "unban"} {e.startTime} {e.seconds}s {e.reasonKey}`)
		end
		return if #lines == 0 then "no history" else table.concat(lines, "\n")
	end, "moderation history <userId>")

	console.register("audit", function(player: any, userId: string?): string
		local uid = if userId ~= nil then id(userId) else nil
		local ok, entries = api.audit({ by = by(player), target = uid })
		if not ok then
			return reply(false, entries)
		end
		local lines = {}
		for _, e in entries do
			table.insert(
				lines,
				`{e.at} {e.byKind}:{e.by} {e.action} {tostring(e.target)} {e.status} {e.reasonKey or e.note or ""}`
			)
		end
		return if #lines == 0 then "no entries" else table.concat(lines, "\n")
	end, "moderation audit [userId]")
end

return Console
