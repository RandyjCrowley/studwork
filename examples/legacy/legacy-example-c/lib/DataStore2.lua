--[[
	DataStore2 (the subset this game uses), "OrderedBackups" saving method:
	  DataStore2.Combine(mainKey, ...keys)   the keys are saved together under mainKey
	  DataStore2(key, player) -> store       store:Get(default), :Set(v), :Increment(n, default),
	                                          :OnUpdate(fn); saved when the player leaves
	Storage: OrderedDataStore "<mainKey>/<userId>" holds versions (key = value = n); DataStore
	"<mainKey>/<userId>" holds the value under key tostring(n) of the newest version.
]]
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local combined = {} -- key -> mainKey
local caches = {} -- player -> mainKey -> { value, version, listeners }

local DataStore2 = {}

function DataStore2.Combine(mainKey, ...)
	for _, key in ipairs({ ... }) do
		combined[key] = mainKey
	end
end

local function load(player, mainKey)
	caches[player] = caches[player] or {}
	local cache = caches[player][mainKey]
	if cache then
		return cache
	end
	local name = mainKey .. "/" .. player.UserId
	local ordered = DataStoreService:GetOrderedDataStore(name)
	local store = DataStoreService:GetDataStore(name)
	local top = ordered:GetSortedAsync(false, 1):GetCurrentPage()[1]
	local value, version = nil, 0
	if top then
		version = top.value
		value = store:GetAsync(tostring(version))
	end
	cache = { value = value or {}, version = version, listeners = {}, dirty = false }
	caches[player][mainKey] = cache
	return cache
end

local function save(player, mainKey, cache)
	if not cache.dirty then
		return
	end
	local name = mainKey .. "/" .. player.UserId
	local version = cache.version + 1
	DataStoreService:GetDataStore(name):SetAsync(tostring(version), cache.value)
	DataStoreService:GetOrderedDataStore(name):SetAsync(tostring(version), version)
	cache.version = version
	cache.dirty = false
end

local Store = {}
Store.__index = Store

function Store:Get(default)
	local cache = load(self.player, self.mainKey)
	local v = cache.value[self.key]
	if v == nil then
		return default
	end
	return v
end

function Store:Set(value)
	local cache = load(self.player, self.mainKey)
	cache.value[self.key] = value
	cache.dirty = true
	for _, fn in ipairs(cache.listeners[self.key] or {}) do
		task.spawn(fn, value)
	end
end

function Store:Increment(n, default)
	self:Set(self:Get(default or 0) + n)
end

function Store:OnUpdate(fn)
	local cache = load(self.player, self.mainKey)
	cache.listeners[self.key] = cache.listeners[self.key] or {}
	table.insert(cache.listeners[self.key], fn)
end

setmetatable(DataStore2, {
	__call = function(_, key, player)
		return setmetatable({ key = key, player = player, mainKey = combined[key] or key }, Store)
	end,
})

Players.PlayerRemoving:Connect(function(player)
	for mainKey, cache in pairs(caches[player] or {}) do
		pcall(save, player, mainKey, cache)
	end
	caches[player] = nil
end)

game:BindToClose(function()
	for player, byKey in pairs(caches) do
		for mainKey, cache in pairs(byKey) do
			pcall(save, player, mainKey, cache)
		end
	end
end)

return DataStore2
