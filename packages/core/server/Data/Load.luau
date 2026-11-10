--!strict
--[[
	Pure load-time decisions for Core.Data. OWNED BY AGENT A. No Roblox globals; tested in Lune.

	Load.awaitStore(isReady, hasFailed, clock, sleep, timeout) -> boolean   (L1)
	  Polls until the store is chosen (true), choosing failed or `timeout` seconds passed (false).

	Load.decide(raw, prepare) -> Decision   (Decision 1)
	  prepare(raw) -> Schema.prepare results (works on a copy). decide never writes into raw:
	  "use"   -> caller assigns decision.data to profile.Data (only for "new"/"ok").
	  "kick"  -> caller ends the session and kicks with decision.message; profile.Data is left as
	             loaded (so the closing save writes back exactly what was there, never defaults).
	             decision.analytics is true for a load failure (DataLoadFailed event).
]]

local Load = {}

Load.KICK_MIGRATION_FAILED = "We couldn't load your save safely. Please rejoin. Your progress is safe."
Load.KICK_NEWER_DATA = "This server is running an older version of the game. Please rejoin to get the latest."
Load.KICK_LOAD_FAILED = "Your save data could not be loaded. Please rejoin in a moment."

export type Report = { inventory: number, other: number }

export type Decision = {
	action: "use" | "kick",
	status: string,
	data: { [string]: any }?,
	message: string?,
	reason: string?,
	analytics: boolean,
	report: Report?,
}

function Load.awaitStore(
	isReady: () -> boolean,
	hasFailed: () -> boolean,
	clock: () -> number,
	sleep: () -> (),
	timeout: number
): boolean
	local deadline = clock() + timeout
	while not isReady() do
		if hasFailed() or clock() >= deadline then
			return false
		end
		sleep()
	end
	return true
end

function Load.decide(
	raw: { [string]: any },
	prepare: (raw: { [string]: any }) -> ({ [string]: any }, string, string?, Report?)
): Decision
	local ok, data, status, message, report = pcall(prepare, raw)
	if not ok then
		-- prepare itself threw: the data can't be understood
		return {
			action = "kick",
			status = "error",
			message = Load.KICK_MIGRATION_FAILED,
			reason = tostring(data),
			analytics = true,
		}
	end
	if status == "new" or status == "ok" then
		if data == raw and next(raw) ~= nil and status == "ok" then
			-- defensive: prepare must work on a copy
			return {
				action = "kick",
				status = "error",
				message = Load.KICK_MIGRATION_FAILED,
				reason = "prepare returned raw",
				analytics = true,
			}
		end
		return { action = "use", status = status, data = data, analytics = false, report = report }
	end
	if status == "newer" then
		return {
			action = "kick",
			status = "newer",
			message = Load.KICK_NEWER_DATA,
			reason = message,
			analytics = false,
		}
	end
	return {
		action = "kick",
		status = "error",
		message = Load.KICK_MIGRATION_FAILED,
		reason = message or ("unknown status " .. tostring(status)),
		analytics = true,
	}
end

-- L7: the warning Data prints when sanitize dropped/repaired entries (nil = nothing to report).
function Load.dropWarning(userId: number, report: Report?): string?
	if report == nil or (report.inventory == 0 and report.other == 0) then
		return nil
	end
	return `[Core.Data] sanitized save of {userId}: dropped {report.inventory} invalid inventory entries, {report.other} other invalid entries/values`
end

return Load
