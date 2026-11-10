--!strict
--[[
	Pure token-bucket rate limiter, keyed by (player key, event name). Clock is injected so it is
	testable under Lune. LEAD-OWNED (core/server/Net).
]]

export type Limit = { rate: number, burst: number } -- tokens per second, bucket size

type Bucket = { tokens: number, last: number }

export type Limiter = {
	allow: (self: Limiter, key: string | number, eventName: string, limit: Limit) -> boolean,
	forget: (self: Limiter, key: string | number) -> (),
}

local RateLimit = {}

function RateLimit.new(clock: () -> number): Limiter
	local buckets: { [string | number]: { [string]: Bucket } } = {}
	local limiter = {}

	function limiter.allow(_self: Limiter, key: string | number, eventName: string, limit: Limit): boolean
		local now = clock()
		local perKey = buckets[key]
		if perKey == nil then
			perKey = {}
			buckets[key] = perKey
		end
		local bucket = perKey[eventName]
		if bucket == nil then
			bucket = { tokens = limit.burst, last = now }
			perKey[eventName] = bucket
		end
		local elapsed = now - bucket.last
		if elapsed ~= elapsed or elapsed < 0 then
			elapsed = 0
		end
		bucket.tokens = math.min(limit.burst, bucket.tokens + elapsed * limit.rate)
		bucket.last = now
		if bucket.tokens >= 1 then
			bucket.tokens -= 1
			return true
		end
		return false
	end

	function limiter.forget(_self: Limiter, key: string | number)
		buckets[key] = nil
	end

	return (limiter :: any) :: Limiter
end

return RateLimit
