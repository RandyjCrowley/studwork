--!nocheck
--[[
	The simulated "Roblox cloud" shared by every simulated server of one test:
	  - one Scheduler (one clock for all servers);
	  - a mock DataStoreService backend (UpdateAsync/GetAsync/SetAsync with deep-copied, JSON-like
	    values, key info, injectable latency and failures, and a write log that records which
	    server wrote what, used to prove "never two writers");
	  - a MessagingService bus (ProfileStore uses it to ask the lock holder to release);
	  - the friend graph, PolicyService answers and game-pass ownership.
	Servers are created with World:server(opts) (see Server.luau).
]]

local Scheduler = require(script.Parent.Scheduler)

local World = {}
World.__index = World

local function deepCopy(value: any, seen: { [any]: boolean }?): any
	local t = type(value)
	if t == "function" or t == "thread" or t == "userdata" then
		error("sim DataStore: value is not serializable (" .. t .. ")", 0)
	end
	if t ~= "table" then
		if t == "number" and value ~= value then
			error("sim DataStore: NaN is not serializable", 0)
		end
		return value
	end
	local s = seen or {}
	if s[value] then
		error("sim DataStore: cyclic table is not serializable", 0)
	end
	s[value] = true
	local copy = {}
	for k, v in value do
		local kt = type(k)
		if kt ~= "string" and kt ~= "number" then
			error("sim DataStore: key type " .. kt .. " is not serializable", 0)
		end
		copy[k] = deepCopy(v, s)
	end
	s[value] = nil
	return copy
end

World.deepCopy = deepCopy

function World.new(opts: { dt: number?, verbose: boolean?, epoch: number? }?)
	local o = opts or {}
	local self = setmetatable({
		scheduler = Scheduler.new({ dt = o.dt, verbose = o.verbose, epoch = o.epoch }),
		verbose = o.verbose == true,
		stores = {}, -- storeName -> key -> entry { value, version, userIds, metadata, created, updated }
		log = {}, -- every committed write: { at, store, key, writer, before, after }
		-- DataStore tuning (seconds). latency: before the atomic read-modify-write commits;
		-- ackLatency: after it committed, before the caller gets the result.
		latency = 0,
		ackLatency = 0,
		failRules = {}, -- { { remaining: number?, until: number?, match: (op, store, key, writer) -> boolean } }
		calls = 0,
		messagingEnabled = true,
		messagingLatency = 0.1,
		topics = {}, -- topic -> { { callback, server } }
		friends = {}, -- userId -> { [userId]: true }
		friendLatency = 0.05,
		friendFailures = 0, -- next N IsFriendsWithAsync calls error
		restricted = {}, -- userId -> true (PolicyService paid random items restricted)
		passes = {}, -- userId -> { [passId]: true }
		servers = {},
		nextJob = 0,
	}, World)
	return self
end

function World.advance(self, seconds: number, dt: number?)
	self.scheduler:advance(seconds, dt)
end

function World.advanceUntil(self, predicate: () -> boolean, maxSeconds: number, dt: number?): boolean
	return self.scheduler:advanceUntil(predicate, maxSeconds, dt)
end

function World.now(self): number
	return self.scheduler:time()
end

-- Errors raised inside simulated threads (should be empty in a healthy scenario).
function World.errors(self): { string }
	local list = {}
	for _, e in self.scheduler.errors do
		table.insert(list, e.message)
	end
	return list
end

--------------------------------------------------------------------------------
-- Friends / policy / passes
--------------------------------------------------------------------------------

function World.setFriends(self, a: number, b: number, are: boolean?)
	local value = if are == false then nil else true
	self.friends[a] = self.friends[a] or {}
	self.friends[b] = self.friends[b] or {}
	self.friends[a][b] = value
	self.friends[b][a] = value
end

function World.areFriends(self, a: number, b: number): boolean
	return self.friends[a] ~= nil and self.friends[a][b] == true
end

--------------------------------------------------------------------------------
-- DataStore backend
--------------------------------------------------------------------------------

-- Fail the next `count` matching DataStore calls (all calls when match is nil).
function World.failNext(
	self,
	count: number,
	match: ((op: string, store: string, key: string, writer: string) -> boolean)?
)
	table.insert(self.failRules, { remaining = count, match = match })
end

-- Fail every matching DataStore call until the virtual clock reaches now + seconds.
function World.failFor(
	self,
	seconds: number,
	match: ((op: string, store: string, key: string, writer: string) -> boolean)?
)
	table.insert(self.failRules, { untilTime = self.scheduler.now + seconds, match = match })
end

function World._shouldFail(self, op: string, store: string, key: string, writer: string): boolean
	for i = #self.failRules, 1, -1 do
		local rule = self.failRules[i]
		local expired = (rule.remaining ~= nil and rule.remaining <= 0)
			or (rule.untilTime ~= nil and self.scheduler.now >= rule.untilTime)
		if expired then
			table.remove(self.failRules, i)
		elseif rule.match == nil or rule.match(op, store, key, writer) then
			if rule.remaining ~= nil then
				rule.remaining -= 1
			end
			return true
		end
	end
	return false
end

local function keyInfo(entry: any)
	return {
		CreatedTime = entry.created,
		UpdatedTime = entry.updated,
		Version = string.format("%016d", entry.version),
		GetMetadata = function()
			return deepCopy(entry.metadata)
		end,
		GetUserIds = function()
			return deepCopy(entry.userIds)
		end,
	}
end

function World._entry(self, storeName: string, key: string): any
	local store = self.stores[storeName]
	return store and store[key]
end

-- Raw stored value (deep copy) of a key, or nil.
function World.peek(self, storeName: string, key: string): any
	local entry = self:_entry(storeName, key)
	return if entry then deepCopy(entry.value) else nil
end

-- Writes a raw value (seeding saves written by "older servers").
function World.seed(self, storeName: string, key: string, value: any)
	self.stores[storeName] = self.stores[storeName] or {}
	local ms = math.floor(self:now() * 1000)
	self.stores[storeName][key] = {
		value = deepCopy(value),
		version = 1,
		userIds = {},
		metadata = {},
		created = ms,
		updated = ms,
	}
end

function World._call(self, op: string, storeName: string, key: string, writer: string)
	self.calls += 1
	local fail = self:_shouldFail(op, storeName, key, writer)
	if self.latency > 0 then
		self.scheduler:wait(self.latency)
	end
	if fail then
		error("503: sim DataStore injected failure (" .. op .. " " .. key .. ")", 0)
	end
end

function World._commit(
	self,
	storeName: string,
	key: string,
	writer: string,
	newValue: any,
	userIds: any,
	metadata: any
)
	self.stores[storeName] = self.stores[storeName] or {}
	local store = self.stores[storeName]
	local entry = store[key]
	local before = entry and entry.value
	local ms = math.floor(self:now() * 1000)
	local stored = deepCopy(newValue)
	if entry == nil then
		entry = { version = 0, created = ms }
		store[key] = entry
	end
	entry.value = stored
	entry.version += 1
	entry.updated = ms
	entry.userIds = deepCopy(userIds or {})
	entry.metadata = deepCopy(metadata or {})
	table.insert(self.log, {
		at = self.scheduler.now,
		store = storeName,
		key = key,
		writer = writer,
		before = if before then deepCopy(before) else nil,
		after = deepCopy(stored),
	})
	return entry
end

-- DataStoreService facade for one server (writer = its JobId).
function World.dataStoreService(self, server: any)
	local world = self
	local service = {}
	function service.GetDataStore(_self, name: string, _scope: string?, _options: any)
		local ds = {}
		function ds.UpdateAsync(_ds, key: string, transform: (any, any) -> (any, any, any))
			world:_call("UpdateAsync", name, key, server.jobId)
			local entry = world:_entry(name, key)
			local current = if entry then deepCopy(entry.value) else nil
			local newValue, userIds, metadata = transform(current, if entry then keyInfo(entry) else nil)
			if newValue == nil then
				if world.ackLatency > 0 then
					world.scheduler:wait(world.ackLatency)
				end
				return nil, nil
			end
			local committed = world:_commit(name, key, server.jobId, newValue, userIds, metadata)
			local result, info = deepCopy(committed.value), keyInfo(committed)
			if world.ackLatency > 0 then
				world.scheduler:wait(world.ackLatency)
			end
			return result, info
		end
		function ds.GetAsync(_ds, key: string)
			world:_call("GetAsync", name, key, server.jobId)
			local entry = world:_entry(name, key)
			if entry == nil then
				return nil, nil
			end
			return deepCopy(entry.value), keyInfo(entry)
		end
		function ds.SetAsync(_ds, key: string, value: any, userIds: any)
			world:_call("SetAsync", name, key, server.jobId)
			world:_commit(name, key, server.jobId, value, userIds, nil)
		end
		function ds.GetVersionAsync()
			error("sim DataStore: GetVersionAsync not modelled", 0)
		end
		return ds
	end
	function service.GetRequestBudgetForRequestType()
		return 1000
	end
	return service
end

--------------------------------------------------------------------------------
-- MessagingService bus
--------------------------------------------------------------------------------

function World.messagingService(self, server: any)
	local world = self
	local service = {}
	function service.SubscribeAsync(_self, topic: string, callback: (any) -> ())
		world.topics[topic] = world.topics[topic] or {}
		local entry = { callback = callback, server = server }
		table.insert(world.topics[topic], entry)
		local connection = { Connected = true }
		function connection.Disconnect(conn)
			conn.Connected = false
			local list = world.topics[topic]
			local index = list and table.find(list, entry)
			if index then
				table.remove(list, index)
			end
		end
		return connection
	end
	function service.PublishAsync(_self, topic: string, message: any)
		if world.messagingLatency > 0 then
			world.scheduler:wait(world.messagingLatency)
		end
		if not world.messagingEnabled then
			return -- dropped (Roblox does not guarantee delivery)
		end
		for _, entry in table.clone(world.topics[topic] or {}) do
			if entry.server.alive then
				world.scheduler:spawn(
					entry.server,
					entry.callback,
					{ Data = deepCopy(message), Sent = world:now() }
				)
			end
		end
	end
	return service
end

--------------------------------------------------------------------------------
-- Servers
--------------------------------------------------------------------------------

function World.server(self, opts: any?)
	local Server = require(script.Parent.Server)
	self.nextJob += 1
	local server = Server.new(self, "job-" .. self.nextJob, opts or {})
	table.insert(self.servers, server)
	return server
end

return World
