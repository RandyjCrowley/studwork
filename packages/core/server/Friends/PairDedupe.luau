--!strict
--[[
	Friend-pair lookups with in-flight dedupe (L4). Pure: the thread resumer is injected
	(task.spawn in Roblox).

	get(key, call) returns (ok, areFriends):
	  - cached result -> returned immediately.
	  - a call for this key already in flight -> the caller waits for it and shares its result
	    (one web call per pair at a time, even when both players' recomputes ask).
	  - otherwise runs call() under pcall. Success is cached when keep(key) says so (e.g. both
	    players still in the server); failures are never cached, so the next check retries.
	forgetUser(userId) drops cached pairs that contain that user (in-flight calls finish, but
	their result is not cached if keep(key) is false by then).
]]

local PairDedupe = {}
PairDedupe.__index = PairDedupe

type Resume = (thread: thread, ok: boolean, value: boolean?) -> ()

export type PairDedupe = typeof(setmetatable(
	{} :: {
		cache: { [string]: boolean },
		inflight: { [string]: { thread } },
		resume: Resume,
		keep: (key: string) -> boolean,
		calls: number,
	},
	PairDedupe
))

function PairDedupe.new(resume: Resume, keep: ((key: string) -> boolean)?): PairDedupe
	return setmetatable({
		cache = {},
		inflight = {},
		resume = resume,
		keep = keep or function()
			return true
		end,
		calls = 0,
	}, PairDedupe)
end

function PairDedupe.get(self: PairDedupe, key: string, call: () -> boolean): (boolean, boolean?)
	local cached = self.cache[key]
	if cached ~= nil then
		return true, cached
	end
	local current = self.inflight[key]
	if current then
		table.insert(current, coroutine.running())
		return coroutine.yield()
	end
	local waiters: { thread } = {}
	self.inflight[key] = waiters
	self.calls += 1
	local ok, result = pcall(call)
	self.inflight[key] = nil
	local value: boolean? = if ok then result == true else nil
	if ok and self.keep(key) then
		self.cache[key] = value :: boolean
	end
	for _, thread in waiters do
		self.resume(thread, ok, value)
	end
	return ok, value
end

function PairDedupe.forgetUser(self: PairDedupe, userId: number)
	local prefix, suffix = tostring(userId) .. ":", ":" .. tostring(userId)
	for key in self.cache do
		if string.sub(key, 1, #prefix) == prefix or string.sub(key, -#suffix) == suffix then
			self.cache[key] = nil
		end
	end
end

return PairDedupe
