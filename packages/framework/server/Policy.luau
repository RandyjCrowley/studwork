--!strict
--[[
	Framework Policy (ported from v1.2 core/server/Policy). Framework internal; modules see the
	read-only ctx.policy = { paidRandomRestricted(player), isKnown(player) }.

	paidRandomRestricted(player) -> PolicyService ArePaidRandomItemsRestricted. FAIL CLOSED: true
	until a lookup succeeds, and true if every attempt fails. Lookup: up to MAX_ATTEMPTS tries with
	exponential backoff (BASE_DELAY * 2^(attempt-1), capped at MAX_DELAY), then a background retry
	every BACKGROUND_RETRY seconds while the player stays (review N2), so a purchase waiting on
	isKnown (tx.retryLater) isn't stuck all session. Replicated to the owning client as the
	framework field `paidRandomRestricted` (true first, then the known value).
	Studio only: console `policy restrict <true|false|clear> [userId]`.

	Policy.new(opts): opts.lookup(player) -> info (yields; may error), opts.isPlayer(player),
	opts.wait(seconds), opts.publish(player, value), opts.log(msg).
]]

local Policy = {}

Policy.MAX_ATTEMPTS = 4
Policy.BACKGROUND_RETRY = 30
Policy.BASE_DELAY = 1
Policy.MAX_DELAY = 8

function Policy.new(opts: any): any
	local lookupFn: (any) -> any = opts.lookup
	local isPlayer: (any) -> boolean = opts.isPlayer
	local wait: (number) -> () = opts.wait
	local publishFn: (any, boolean) -> () = opts.publish
	local log: (string) -> () = opts.log

	local restricted: { [any]: boolean } = {}
	local overrides: { [any]: boolean } = {}
	local tracking: { [any]: boolean } = {}

	local p: any = {}

	local function effective(player: any): boolean
		local o = overrides[player]
		if o ~= nil then
			return o
		end
		local value = restricted[player]
		if value == nil then
			return true
		end
		return value
	end

	local function publish(player: any)
		if isPlayer(player) then
			publishFn(player, effective(player))
		end
	end

	local function tryOnce(player: any): boolean
		local ok, info = pcall(lookupFn, player)
		if ok and type(info) == "table" and type(info.ArePaidRandomItemsRestricted) == "boolean" then
			if isPlayer(player) then
				restricted[player] = info.ArePaidRandomItemsRestricted
				publish(player)
			end
			return true
		end
		return false
	end

	-- Runs in its own thread (yields).
	function p.track(player: any)
		if tracking[player] then
			return
		end
		tracking[player] = true
		publish(player) -- fail closed while unknown
		for attempt = 1, Policy.MAX_ATTEMPTS do
			if not isPlayer(player) then
				return
			end
			if tryOnce(player) then
				return
			end
			if attempt < Policy.MAX_ATTEMPTS then
				wait(math.min(Policy.BASE_DELAY * 2 ^ (attempt - 1), Policy.MAX_DELAY))
			else
				log(
					`[StudWork.Policy] lookup failed for {tostring(player)}; staying restricted, retrying every {Policy.BACKGROUND_RETRY}s`
				)
			end
		end
		while isPlayer(player) and restricted[player] == nil do
			wait(Policy.BACKGROUND_RETRY)
			if not isPlayer(player) then
				return
			end
			if tryOnce(player) then
				return
			end
		end
	end

	function p.forget(player: any)
		restricted[player] = nil
		overrides[player] = nil
		tracking[player] = nil
	end

	function p.isKnown(player: any): boolean
		return overrides[player] ~= nil or restricted[player] ~= nil
	end

	function p.paidRandomRestricted(player: any): boolean
		return effective(player)
	end

	-- Studio console override (true / false / nil = clear).
	function p.override(player: any, value: boolean?)
		overrides[player] = value
		publish(player)
	end

	p.api = table.freeze({
		paidRandomRestricted = p.paidRandomRestricted,
		isKnown = p.isKnown,
	})

	return p
end

return Policy
