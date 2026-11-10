--!strict
--[[
	Save stores for framework Data (Data.luau documents the interface).

	Store.memory()          in-memory saves + messages (tests, harness; nothing persists)
	Store.profileStore(opts) ProfileStore 1.0.3 (ported from v1.2 core/server/Data):
	  - store ProfileStore.New("PlayerData_" .. gameId) live, "PlayerData_<gameId>_Studio" in Studio
	    with API access; Studio without DataStore access -> store.Mock (warned once; nothing
	    persists across runs). Key "Player_" .. userId, profile:AddUserId(userId) (GDPR).
	  - load: waits for the store (STORE_WAIT_TIMEOUT, then the load fails -> kick, L1), then
	    StartSessionAsync with Cancel = "the player left". Returns profile.Data (a fresh profile is {}).
	  - reject: a load the framework refused (bad / newer data) ends the session WITHOUT replacing
	    profile.Data, so the closing save writes back exactly what was loaded.
	  - attach: profile.Data = the framework's live root (commits replace sections in place, so
	    every autosave carries them). OnSave -> hooks.beforeSave (lastSeen, purchases cap).
	    OnSessionEnd after OnLastSave("External") -> hooks.sessionLost: the save was opened by
	    another server; the framework drops the record (no more writes) and kicks.
	  - saveNow (saveAsync): stamps a sequence number into _framework.stats._saveSeq, Save(), and
	    waits until a SUCCESSFUL save's payload carries it (OnAfterSave), up to SAVE_TIMEOUT.
	  - release: EndSession (OnSave stamps lastSeen right before the final write).
	  - send/onMessage/nudge: ProfileStore MessageAsync / MessageHandler / an early Save() so
	    in-server messages land fast.
	opts: gameId, isStudio, serverPackages (folder holding ProfileStore), wait(seconds), clock(),
	spawn(fn), log(msg), isPlayer(player).
]]

local Store = {}

Store.SAVE_TIMEOUT = 30
Store.STORE_STATE_TIMEOUT = 15
Store.STORE_WAIT_TIMEOUT = 30
Store.SAVE_SEQ_KEY = "_saveSeq"

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

function Store.memory(): any
	local saves: { [any]: any } = {}
	local inbox: { [any]: { any } } = {}
	local receivers: { [any]: (any, () -> ()) -> () } = {}
	local s: any = { saves = saves, inbox = inbox }

	function s.load(userId: any): any
		return deepCopy(saves[userId])
	end
	function s.save(userId: any, root: any)
		saves[userId] = deepCopy(root)
	end
	local function deliver(userId: any)
		local fn = receivers[userId]
		local queue = inbox[userId]
		if fn == nil or queue == nil then
			return
		end
		for _, entry in table.clone(queue) do
			if not entry.done then
				fn(deepCopy(entry.message), function()
					entry.done = true
					local i = table.find(queue, entry)
					if i then
						table.remove(queue, i)
					end
				end)
			end
		end
	end
	function s.send(userId: any, message: any): boolean
		inbox[userId] = inbox[userId] or {}
		table.insert(inbox[userId], { message = deepCopy(message), done = false })
		deliver(userId)
		return true
	end
	function s.onMessage(userId: any, fn: (any, () -> ()) -> ())
		receivers[userId] = fn
		deliver(userId)
	end
	function s.release(userId: any, root: any)
		receivers[userId] = nil
		s.save(userId, root)
	end
	return s
end

function Store.profileStore(opts: any): any
	local log: (string) -> () = opts.log
	local wait: (number?) -> () = opts.wait
	local clock: () -> number = opts.clock
	local ProfileStore: any = nil
	local base: any = nil
	local ready = false
	local failedChoose = false
	local profiles: { [any]: any } = {}
	local entries: { [any]: { saveSeq: number, committedSeq: number, root: any } } = {}

	local function choose()
		local ok, err = pcall(function()
			ProfileStore = (require :: any)(opts.serverPackages:WaitForChild("ProfileStore"))
			local name = "PlayerData_" .. tostring(opts.gameId)
			if opts.isStudio then
				name ..= "_Studio"
				local deadline = clock() + Store.STORE_STATE_TIMEOUT
				while ProfileStore.DataStoreState == "NotReady" and clock() < deadline do
					wait(0.1)
				end
			end
			local made = ProfileStore.New(name, {})
			if opts.isStudio and ProfileStore.DataStoreState ~= "Access" then
				log(
					`[StudWork.Data] DataStore API unavailable in Studio ({ProfileStore.DataStoreState}); using ProfileStore.Mock - data will not persist.`
				)
				base = made.Mock
			else
				base = made
			end
			ready = true
		end)
		if not ok then
			failedChoose = true
			log(`[StudWork.Data] could not select a ProfileStore: {tostring(err)}`)
		end
	end
	opts.spawn(choose)

	local function key(userId: any): string
		return "Player_" .. tostring(userId)
	end

	local function awaitStore(): boolean
		local deadline = clock() + Store.STORE_WAIT_TIMEOUT
		while not ready and not failedChoose and clock() < deadline do
			wait(0.1)
		end
		return ready
	end

	local s: any = {}

	function s.load(userId: any, player: any): any
		if not awaitStore() then
			error("no ProfileStore (failed or timed out)", 0)
		end
		local profile = base:StartSessionAsync(key(userId), {
			Cancel = function()
				return not opts.isPlayer(player)
			end,
		})
		if profile == nil then
			error("StartSessionAsync returned no profile (session lock busy, or the player left)", 0)
		end
		if not opts.isPlayer(player) then
			profile:EndSession()
			error("player left while loading", 0)
		end
		profiles[userId] = profile
		return profile.Data
	end

	function s.reject(userId: any)
		local profile = profiles[userId]
		profiles[userId] = nil
		if profile and profile:IsActive() then
			profile:EndSession() -- profile.Data untouched: writes back what was loaded
		end
	end

	function s.attach(userId: any, root: any, hooks: any)
		local profile = profiles[userId]
		assert(profile ~= nil, "Store.attach before load")
		local stats = type(root._framework) == "table" and root._framework.stats
		local stored = type(stats) == "table" and stats[Store.SAVE_SEQ_KEY]
		local seq = if type(stored) == "number" and stored == stored then stored else 0
		local entry = { saveSeq = seq, committedSeq = seq, root = root }
		entries[userId] = entry
		profile.Data = root
		profile:AddUserId(userId)
		profile.OnSave:Connect(function()
			hooks.beforeSave()
		end)
		profile.OnAfterSave:Connect(function(lastSaved: any)
			local fw = type(lastSaved) == "table" and lastSaved._framework
			local st = type(fw) == "table" and fw.stats
			local n = type(st) == "table" and st[Store.SAVE_SEQ_KEY]
			if type(n) == "number" and n > entry.committedSeq then
				entry.committedSeq = n
			end
		end)
		local lastSaveReason: string? = nil
		profile.OnLastSave:Connect(function(reason: string)
			lastSaveReason = reason
		end)
		profile.OnSessionEnd:Connect(function()
			if profiles[userId] == profile then
				profiles[userId] = nil
				entries[userId] = nil
			end
			if lastSaveReason == "External" then
				hooks.sessionLost()
			end
		end)
	end

	function s.save(_userId: any, _root: any)
		-- ProfileStore autosaves profile.Data (the live root); nothing to do.
	end

	function s.saveNow(userId: any, root: any): boolean
		local profile = profiles[userId]
		local entry = entries[userId]
		if profile == nil or entry == nil or not profile:IsActive() then
			return false
		end
		entry.saveSeq = math.max(entry.saveSeq, entry.committedSeq) + 1
		local target = entry.saveSeq
		root._framework.stats = root._framework.stats or {}
		root._framework.stats[Store.SAVE_SEQ_KEY] = target
		profile:Save()
		local deadline = clock() + Store.SAVE_TIMEOUT
		while entry.committedSeq < target do
			if entries[userId] ~= entry or clock() > deadline then
				return entry.committedSeq >= target
			end
			wait()
		end
		return true
	end

	function s.release(userId: any, _root: any)
		local profile = profiles[userId]
		if profile and profile:IsActive() then
			profile:EndSession()
		end
	end

	function s.send(userId: any, message: any): boolean
		if not awaitStore() then
			return false
		end
		return base:MessageAsync(key(userId), message) == true
	end

	function s.onMessage(userId: any, fn: (any, () -> ()) -> ())
		local profile = profiles[userId]
		if profile then
			profile:MessageHandler(function(message: any, processed: () -> ())
				fn(message, processed)
			end)
		end
	end

	function s.nudge(userId: any)
		local profile = profiles[userId]
		if profile and profile:IsActive() then
			profile:Save()
		end
	end

	return s
end

return Store
