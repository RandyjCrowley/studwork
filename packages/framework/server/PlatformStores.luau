--!strict
--[[
	The live store adapters (framework internal): the engine's DataStore / MemoryStore services
	behind the backend interfaces OrderedStore.luau and SortedMapStore.luau call (their headers
	list the methods). The only place the framework's ordered stores and sorted maps meet the engine.

	  PlatformStores.live(opts) -> { ordered(storeName) -> backend, sortedMap(storeName) -> backend }
	  PlatformStores.inert()    -> the same shape; every call raises "no store backend" (Platform.inert)

	STUB (foundation): both constructors return backends whose every method raises
	"not implemented: PlatformStores.<surface>", which the store layers turn into (false, "failed").
	The live adapters (GetOrderedDataStore with the `_Studio` fallback to memory, MemoryStoreService
	sorted maps, error-code passthrough) are the stores builder's (B1).
]]

local PlatformStores = {}

local function stubBackend(label: string, methods: { string }): any
	local b: any = {}
	for _, method in methods do
		b[method] = function()
			error(`not implemented: PlatformStores.{label}.{method}`, 0)
		end
	end
	return b
end

local ORDERED_METHODS = { "get", "set", "increment", "update", "remove", "top" }
local SORTED_METHODS = { "get", "set", "update", "remove", "range" }

function PlatformStores.live(_opts: any?): any
	return {
		ordered = function(_storeName: string): any
			return stubBackend("ordered", ORDERED_METHODS)
		end,
		sortedMap = function(_storeName: string): any
			return stubBackend("sortedMap", SORTED_METHODS)
		end,
	}
end

function PlatformStores.inert(): any
	local function none(methods: { string }): any
		local b: any = {}
		for _, method in methods do
			b[method] = function()
				error("no store backend: this platform has no ordered stores or sorted maps", 0)
			end
		end
		return b
	end
	return {
		ordered = function(_storeName: string): any
			return none(ORDERED_METHODS)
		end,
		sortedMap = function(_storeName: string): any
			return none(SORTED_METHODS)
		end,
	}
end

return PlatformStores
