--!nocheck
--[[
	Virtual clock + cooperative task scheduler for the multi-server simulation (agent C, core v1.2).
	Not part of the Rojo tree (packages/framework/test is test-only) and not type-checked by
	tools/typecheck (like harness.luau).

	One Scheduler is shared by every simulated server of a World, so all servers see ONE clock.
	Time only moves when a test calls advance(): no real waiting.

	Model (mirrors the Roblox task library closely enough for core's lifecycle code):
	  - spawn(owner, fnOrThread, ...)   resumes at once; the thread runs until its first yield.
	  - wait(seconds?)                  registers the RUNNING thread with a wake time, then yields.
	                                    It resumes on the first frame at/after the wake time and
	                                    never in the same frame it started waiting (task.wait()
	                                    = next frame). Registering before yielding means it does
	                                    not matter WHO resumed the thread earlier: ProfileStore
	                                    parks/resumes threads with raw coroutine.yield/resume
	                                    (WaitInUpdateQueue) and those threads may task.wait later.
	  - delay / defer / cancel          as in Roblox; defer runs at the end of the current step.
	  - frame hooks                     step(dt) moves the clock, runs every frame hook (servers
	                                    fire their RunService.Heartbeat there), then resumes every
	                                    due sleeper in wake order, then deferred threads.
	  - owners                          every thread belongs to an owner (a simulated server).
	                                    kill(owner) drops all of its threads: a crashed server
	                                    simply stops (in-flight DataStore calls never commit).
	Errors inside threads are collected in `errors` (and printed when `verbose`).
]]

local Scheduler = {}
Scheduler.__index = Scheduler

export type Scheduler = typeof(setmetatable({} :: any, Scheduler))

function Scheduler.new(opts: { dt: number?, epoch: number?, verbose: boolean? }?)
	local o = opts or {}
	local self = setmetatable({
		now = 0, -- virtual seconds since the world started (os.clock())
		epoch = o.epoch or 1_700_000_000, -- os.time() = floor(epoch + now)
		frame = 0,
		dt = o.dt or 1 / 32, -- default frame length (exact in binary, so sums stay exact)
		seq = 0,
		sleepers = {}, -- thread -> { wake, minFrame, seq, start, args? }
		deferred = {}, -- { { thread, args } }
		hooks = {}, -- { { owner, fn } } run every frame (Heartbeat)
		owner = setmetatable({}, { __mode = "k" }), -- thread -> owner
		dead = {}, -- owner -> true once killed
		errors = {}, -- { { owner, message } }
		verbose = o.verbose == true,
	}, Scheduler)
	return self
end

function Scheduler.time(self): number
	return math.floor(self.epoch + self.now)
end

function Scheduler._nextSeq(self): number
	self.seq += 1
	return self.seq
end

function Scheduler._resume(self, thread: thread, ...)
	local owner = self.owner[thread]
	if owner ~= nil and self.dead[owner] then
		return
	end
	if coroutine.status(thread) ~= "suspended" then
		return
	end
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		local message = tostring(err) .. "\n" .. debug.traceback(thread)
		table.insert(self.errors, { owner = owner, message = message })
		if self.verbose then
			print("[sim] thread error (" .. tostring(owner and owner.name) .. "): " .. message)
		end
	end
end

-- Runs `fnOrThread` now, owned by `owner` (a thread keeps an owner it already had).
function Scheduler.spawn(self, owner: any, fnOrThread: any, ...): thread
	local thread = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
	if self.owner[thread] == nil then
		self.owner[thread] = owner
	end
	self.sleepers[thread] = nil
	self:_resume(thread, ...)
	return thread
end

function Scheduler.defer(self, owner: any, fnOrThread: any, ...): thread
	local thread = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
	if self.owner[thread] == nil then
		self.owner[thread] = owner
	end
	table.insert(self.deferred, { thread = thread, args = table.pack(...) })
	return thread
end

function Scheduler.delay(self, owner: any, seconds: number?, fnOrThread: any, ...): thread
	local thread = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
	if self.owner[thread] == nil then
		self.owner[thread] = owner
	end
	self.sleepers[thread] = {
		wake = self.now + math.max(seconds or 0, 0),
		minFrame = self.frame + 1,
		seq = self:_nextSeq(),
		start = self.now,
		args = table.pack(...),
	}
	return thread
end

-- Must be called from inside a scheduler-owned coroutine (task.wait).
function Scheduler.wait(self, seconds: number?): number
	local thread = coroutine.running()
	assert(coroutine.isyieldable(), "sim: task.wait called outside a simulated thread")
	local start = self.now
	self.sleepers[thread] = {
		wake = self.now + math.max(seconds or 0, 0),
		minFrame = self.frame + 1,
		seq = self:_nextSeq(),
		start = start,
	}
	coroutine.yield()
	return self.now - start
end

function Scheduler.cancel(self, thread: thread)
	self.sleepers[thread] = nil
	for i = #self.deferred, 1, -1 do
		if self.deferred[i].thread == thread then
			table.remove(self.deferred, i)
		end
	end
	if coroutine.status(thread) == "suspended" then
		pcall(coroutine.close, thread)
	end
end

function Scheduler.addHook(self, owner: any, fn: (dt: number) -> ())
	table.insert(self.hooks, { owner = owner, fn = fn })
end

-- Stops every thread and hook of `owner` (server crash or finished shutdown).
function Scheduler.kill(self, owner: any)
	self.dead[owner] = true
	for thread in table.clone(self.sleepers) do
		if self.owner[thread] == owner then
			self.sleepers[thread] = nil
		end
	end
	for i = #self.hooks, 1, -1 do
		if self.hooks[i].owner == owner then
			table.remove(self.hooks, i)
		end
	end
end

function Scheduler._runDeferred(self)
	local guard = 0
	while #self.deferred > 0 do
		guard += 1
		assert(guard < 100000, "sim: deferred threads keep re-deferring")
		local batch = self.deferred
		self.deferred = {}
		for _, item in batch do
			self:_resume(item.thread, table.unpack(item.args, 1, item.args.n))
		end
	end
end

-- One frame: clock += dt, Heartbeat hooks, due sleepers (wake order), deferred.
function Scheduler.step(self, dt: number?)
	local d = dt or self.dt
	self.frame += 1
	self.now += d
	for _, hook in table.clone(self.hooks) do
		if not self.dead[hook.owner] then
			self:spawn(hook.owner, hook.fn, d)
		end
	end
	self:_runDeferred()
	while true do
		local due = {}
		for thread, entry in self.sleepers do
			if entry.wake <= self.now + 1e-9 and entry.minFrame <= self.frame then
				table.insert(due, { thread = thread, entry = entry })
			end
		end
		if #due == 0 then
			break
		end
		table.sort(due, function(a, b)
			if a.entry.wake ~= b.entry.wake then
				return a.entry.wake < b.entry.wake
			end
			return a.entry.seq < b.entry.seq
		end)
		for _, item in due do
			-- skip if it was cancelled/re-registered by an earlier resume in this batch
			if self.sleepers[item.thread] == item.entry then
				self.sleepers[item.thread] = nil
				local args = item.entry.args
				if args then
					self:_resume(item.thread, table.unpack(args, 1, args.n))
				else
					self:_resume(item.thread, self.now - item.entry.start)
				end
			end
		end
		self:_runDeferred()
	end
end

-- Advances the clock by `seconds` in frames of `dt` (default self.dt).
function Scheduler.advance(self, seconds: number, dt: number?)
	local d = dt or self.dt
	local target = self.now + seconds
	while self.now + 1e-9 < target do
		self:step(math.min(d, target - self.now))
	end
end

-- Advances until predicate() is true; returns true, or false after `maxSeconds`.
function Scheduler.advanceUntil(self, predicate: () -> boolean, maxSeconds: number, dt: number?): boolean
	local d = dt or self.dt
	local target = self.now + maxSeconds
	self:_runDeferred()
	while not predicate() do
		if self.now + 1e-9 >= target then
			return false
		end
		self:step(math.min(d, target - self.now))
	end
	return true
end

return Scheduler
