--!strict
--[[
	Notifications: the server part (docs/framework/kits/notifications.md).

	FOUNDATION SKELETON: a valid, empty part. `api` answers with the documented safe defaults
	(nothing is sent, nothing queued) and `actions` accept and ignore their calls, so a game can list
	the module and boot. The notifications builder (B6) implements the whole page: the due list and
	ledger on ctx.data.sortedMap, sends through ctx.openCloud, the opt-in rules, join handling and
	the Streak integration.
]]

local Notifications = {}

function Notifications.init(_context: any) end -- STUB (B6)

function Notifications.start(_context: any) end -- STUB (B6)

-- net.blink events OptInShown and SetUtcOffset (rate limits from the page: 1/s burst 2; 1 per 10 s)
Notifications.actions = {
	optInShown = {
		limit = { rate = 1, burst = 2 },
		handler = function(_player: any, _requestId: any, _shown: any) end, -- STUB (B6)
	},
	setUtcOffset = {
		limit = { rate = 0.1, burst = 1 },
		handler = function(_player: any, _hours: any) end, -- STUB (B6)
	},
}

Notifications.api = {
	-- STUB (B6): every call is refused as disabled until the module is implemented
	send = function(_userId: number, _templateKey: string, _params: any?): (boolean, string?)
		return false, "disabled"
	end,
	schedule = function(
		_userId: number,
		_templateKey: string,
		_at: number,
		_params: any?,
		_key: string?
	): (boolean, string?)
		return false, "disabled"
	end,
	cancel = function(_userId: number, _key: string): boolean
		return false
	end,
	suggestOptIn = function(_player: any, _reason: string): boolean
		return false
	end,
}

return Notifications
