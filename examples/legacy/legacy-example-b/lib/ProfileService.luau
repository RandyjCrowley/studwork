--[[
	ProfileService (session-locked profiles on a DataStore), the subset this game uses:
	ProfileService.GetProfileStore(name, template) -> store
	store:LoadProfileAsync(key, notReleasedHandler?) -> profile?   ("ForceLoad" steals after a timeout)
	profile.Data, profile:Reconcile(), profile:AddUserId(id), profile:ListenToRelease(fn),
	profile:Release(), profile:IsActive()
	Stored value: { Data, MetaData = { ProfileCreateTime, SessionLoadCount, ActiveSession =
	{ placeId, jobId } | nil, ForceLoadSession, MetaTags, LastUpdate }, GlobalUpdates = { 0, {} } }
]]
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local AUTOSAVE_SECONDS = 90
local ASSUME_DEAD_SECONDS = 630

local ProfileService = {}

local function deepCopy(t)
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in pairs(t) do
		out[k] = deepCopy(v)
	end
	return out
end

local function reconcile(target, template)
	for k, v in pairs(template) do
		if type(k) == "string" then
			if target[k] == nil then
				target[k] = deepCopy(v)
			elseif type(target[k]) == "table" and type(v) == "table" then
				reconcile(target[k], v)
			end
		end
	end
end

local Profile = {}
Profile.__index = Profile

function Profile:Reconcile()
	reconcile(self.Data, self._template)
end

function Profile:AddUserId(userId)
	self._userIds[userId] = true
end

function Profile:ListenToRelease(fn)
	table.insert(self._releaseListeners, fn)
end

function Profile:IsActive()
	return self._active
end

function Profile:_save(release)
	local session = { game.PlaceId, game.JobId }
	local stolen = false
	self._store:UpdateAsync(self._key, function(stored)
		stored = stored or { Data = {}, MetaData = {} }
		local active = stored.MetaData.ActiveSession
		if active and (active[1] ~= session[1] or active[2] ~= session[2]) then
			stolen = true
			return nil
		end
		stored.Data = self.Data
		stored.MetaData.LastUpdate = os.time()
		stored.MetaData.ActiveSession = if release then nil else session
		return stored
	end)
	if stolen then
		self:_end()
	end
end

function Profile:_end()
	if not self._active then
		return
	end
	self._active = false
	for _, fn in ipairs(self._releaseListeners) do
		task.spawn(fn)
	end
end

function Profile:Release()
	if self._active then
		pcall(function()
			self:_save(true)
		end)
		self:_end()
	end
end

local ProfileStore = {}
ProfileStore.__index = ProfileStore

function ProfileService.GetProfileStore(name, template)
	return setmetatable({ _name = name, _template = template, _store = DataStoreService:GetDataStore(name) }, ProfileStore)
end

function ProfileStore:LoadProfileAsync(key)
	local session = { game.PlaceId, game.JobId }
	local loaded
	for _ = 1, 5 do
		local ok = pcall(function()
			self._store:UpdateAsync(key, function(stored)
				stored = stored
					or {
						Data = deepCopy(self._template),
						MetaData = { ProfileCreateTime = os.time(), SessionLoadCount = 0, MetaTags = {} },
						GlobalUpdates = { 0, {} },
					}
				local meta = stored.MetaData
				local active = meta.ActiveSession
				local dead = meta.LastUpdate and os.time() - meta.LastUpdate > ASSUME_DEAD_SECONDS
				if active and not dead and (active[1] ~= session[1] or active[2] ~= session[2]) then
					meta.ForceLoadSession = session
					loaded = nil
					return stored
				end
				meta.ActiveSession = session
				meta.ForceLoadSession = nil
				meta.SessionLoadCount = (meta.SessionLoadCount or 0) + 1
				meta.LastUpdate = os.time()
				loaded = stored
				return stored
			end)
		end)
		if ok and loaded then
			break
		end
		task.wait(5)
	end
	if not loaded then
		return nil
	end
	local profile = setmetatable({
		Data = loaded.Data,
		MetaData = loaded.MetaData,
		_template = self._template,
		_store = self._store,
		_key = key,
		_userIds = {},
		_releaseListeners = {},
		_active = true,
	}, Profile)
	task.spawn(function()
		while profile._active do
			task.wait(AUTOSAVE_SECONDS)
			if profile._active then
				pcall(function()
					profile:_save(false)
				end)
			end
		end
	end)
	return profile
end

if RunService:IsStudio() then
	ProfileService.IsStudio = true
end

return ProfileService
