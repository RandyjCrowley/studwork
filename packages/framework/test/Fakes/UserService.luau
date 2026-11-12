--!strict
--[[
	Fake UserService (StudWork.test.fakes.userService, module-api.md §23.10): display-name lookups for
	ctx.services.get("UserService"). Records every call, never talks to Roblox.

	  local fake = StudWork.test.fakes.userService({
	    users = { [userId] = { Username = "a", DisplayName = "A", HasVerifiedBadge = false } },
	    missing = { userId, ... },     left out of the answer (a banned or deleted account)
	    failNext = n,                  the next n calls raise
	  })
	  harness({ services = { UserService = fake } })

	Engine surface: GetUserInfosByUserIdsAsync({ userId }) -> { { Id, Username, DisplayName, HasVerifiedBadge } }
	(unknown ids get Username "user<id>" and DisplayName "User <id>"). Test surface: calls
	{ { method, userIds } }, failNext(n), lookups() -> number of calls.
]]

local UserFake = {}

function UserFake.new(opts: any?): any
	local o = opts or {}
	local users: { [number]: any } = o.users or {}
	local missing: { [number]: boolean } = {}
	for _, id in (o.missing or {}) :: any do
		missing[id] = true
	end
	local failures = if type(o.failNext) == "number" then o.failNext else 0
	local fake: any = { calls = {} }

	function fake.failNext(n: number)
		failures += n
	end

	function fake.lookups(): number
		return #fake.calls
	end

	function fake.GetUserInfosByUserIdsAsync(_self: any, userIds: { number }): { any }
		table.insert(fake.calls, { method = "GetUserInfosByUserIdsAsync", userIds = table.clone(userIds) })
		if failures > 0 then
			failures -= 1
			error("UserService:GetUserInfosByUserIdsAsync failed (injected)", 0)
		end
		local out = {}
		for _, id in userIds do
			if not missing[id] then
				local u = users[id] or {}
				table.insert(out, {
					Id = id,
					Username = u.Username or `user{id}`,
					DisplayName = u.DisplayName or `User {id}`,
					HasVerifiedBadge = u.HasVerifiedBadge == true,
				})
			end
		end
		return out
	end

	return fake
end

return UserFake
