--!strict
--[[
	The server's opt-in rules (docs/framework/kits/notifications.md, config `optIn`). Pure: it decides
	from numbers, never from a player object. Roblox's own rules (13+, not already opted in, once per 30
	days) are enforced by the client check; this only keeps the game from asking at a bad moment or too often.

	  OptInRules.check(optIn, state, viaSuggest) -> (boolean, reason?)
	    state = { now, joinedAt, sessions, prompts, lastPromptAt, pendingAt?, promptedThisSession }
	    reasons: "not_suggested" (onSuggest = false), "too_early" (minSessionSeconds not reached: never on
	    join), "sessions" (minSessions), "max_prompts", "cooldown" (cooldownDays), "pending" (a request is
	    waiting for its answer), "asked" (already asked in this session)
]]

local OptInRules = {}

export type State = {
	now: number,
	joinedAt: number,
	sessions: number,
	prompts: number,
	lastPromptAt: number,
	pendingAt: number?,
	promptedThisSession: boolean,
}

OptInRules.PENDING_SECONDS = 300 -- how long a request waits for the client's answer

function OptInRules.check(optIn: any, state: State, viaSuggest: boolean): (boolean, string?)
	if viaSuggest and optIn.onSuggest == false then
		return false, "not_suggested"
	end
	if state.promptedThisSession then
		return false, "asked"
	end
	if state.pendingAt ~= nil and state.now - state.pendingAt < OptInRules.PENDING_SECONDS then
		return false, "pending"
	end
	if state.now - state.joinedAt < optIn.minSessionSeconds then
		return false, "too_early"
	end
	-- the current session is not finished: `sessions` counts it
	if state.sessions - 1 < optIn.minSessions then
		return false, "sessions"
	end
	if state.prompts >= optIn.maxPrompts then
		return false, "max_prompts"
	end
	if state.lastPromptAt > 0 and state.now - state.lastPromptAt < optIn.cooldownDays * 86400 then
		return false, "cooldown"
	end
	return true, nil
end

return OptInRules
