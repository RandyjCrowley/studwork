--!strict
--[[
	Fake BadgeService (StudWork.test.fakes.badgeService, module-api.md §23.10), the stand-in the harness
	hands to ctx.services.get("BadgeService"). Records every call, never talks to Roblox.

	  local fake = StudWork.test.fakes.badgeService({
	    owned = { [userId] = { badgeId, ... } },   badges a user already owns
	    disabled = { badgeId, ... },               GetBadgeInfoAsync reports IsEnabled = false
	    names = { [badgeId] = "Name" },            GetBadgeInfoAsync names (default "Badge <id>")
	    failNext = n,                              the next n calls raise
	  })
	  harness({ services = { BadgeService = fake } })

	Engine methods (they yield on the real service):
	  AwardBadgeAsync(userId, badgeId) -> boolean   true = newly awarded; false = the user already owns it
	  CheckUserBadgesAsync(userId, { badgeId }) -> { badgeId }   the ones owned
	  GetBadgeInfoAsync(badgeId) -> { Name, Description, IsEnabled, IconImageId }
	  (AwardBadge and UserHasBadgeAsync are provided too, same behaviour)
	Test surface: calls { { method, userId?, badgeId?, badgeIds? } }, failNext(n), own(userId, badgeId),
	disable(badgeId, bool?), owns(userId, badgeId) -> boolean, awarded() -> { { userId, badgeId } }.
]]

local BadgeFake = {}

function BadgeFake.new(opts: any?): any
	local o = opts or {}
	local owned: { [number]: { [number]: boolean } } = {}
	local disabled: { [number]: boolean } = {}
	local names: { [number]: string } = o.names or {}
	local failures = if type(o.failNext) == "number" then o.failNext else 0
	local awardedLog: { any } = {}
	local fake: any = { calls = {} }

	for userId, ids in (o.owned or {}) :: any do
		owned[userId] = {}
		for _, id in ids do
			owned[userId][id] = true
		end
	end
	for _, id in (o.disabled or {}) :: any do
		disabled[id] = true
	end

	local function enter(method: string, info: any)
		info.method = method
		table.insert(fake.calls, info)
		if failures > 0 then
			failures -= 1
			error(`BadgeService:{method} failed (injected)`, 0)
		end
	end

	function fake.failNext(n: number)
		failures += n
	end

	function fake.own(userId: number, badgeId: number)
		owned[userId] = owned[userId] or {}
		owned[userId][badgeId] = true
	end

	function fake.disable(badgeId: number, value: boolean?)
		disabled[badgeId] = if value == false then nil else true
	end

	function fake.owns(userId: number, badgeId: number): boolean
		return owned[userId] ~= nil and owned[userId][badgeId] == true
	end

	function fake.awarded(): { any }
		return table.clone(awardedLog)
	end

	function fake.AwardBadgeAsync(_self: any, userId: number, badgeId: number): boolean
		enter("AwardBadgeAsync", { userId = userId, badgeId = badgeId })
		if fake.owns(userId, badgeId) then
			return false
		end
		fake.own(userId, badgeId)
		table.insert(awardedLog, { userId = userId, badgeId = badgeId })
		return true
	end
	fake.AwardBadge = fake.AwardBadgeAsync

	function fake.UserHasBadgeAsync(_self: any, userId: number, badgeId: number): boolean
		enter("UserHasBadgeAsync", { userId = userId, badgeId = badgeId })
		return fake.owns(userId, badgeId)
	end

	function fake.CheckUserBadgesAsync(_self: any, userId: number, badgeIds: { number }): { number }
		enter("CheckUserBadgesAsync", { userId = userId, badgeIds = table.clone(badgeIds) })
		local out = {}
		for _, id in badgeIds do
			if fake.owns(userId, id) then
				table.insert(out, id)
			end
		end
		return out
	end

	function fake.GetBadgeInfoAsync(_self: any, badgeId: number): any
		enter("GetBadgeInfoAsync", { badgeId = badgeId })
		return {
			Name = names[badgeId] or `Badge {badgeId}`,
			Description = "",
			IsEnabled = not disabled[badgeId],
			IconImageId = 0,
		}
	end

	return fake
end

return BadgeFake
