--!nocheck
--[[
	The sim's MemoryStore / OrderedDataStore stand-ins (module-api.md §23.10): one registry per World,
	shared by every simulated server (so servers see each other's sorted maps and ordered stores,
	and the per-structure / per-partition limits and the memory quota are the experience's), on the
	World's clock (expiry follows `world:advance`).

	  MemoryStores.new(world, opts?) -> registry       Fakes.memoryStores(...) on the world's scheduler clock
	      opts = { sortedMap = { structureLimit?, partitionLimit?, quotaBytes? }? }
	      (World.new({ memoryStores = opts }))
	  MemoryStores.platform(registry) -> { stores = { ordered(storeName), sortedMap(storeName) } }
	                                                   the fragment a sim server's platform uses

	  - Ordered stores are the World's own ordered backend (world.stores["ordered:<storeName>"],
	    the one DataStore2-style legacy imports read; world:setOrdered seeds it), reached through the
	    live adapter (PlatformStores.orderedAdapter): world:failNext / failFor rules (store
	    "ordered:<storeName>"), latency and the write log apply as to any DataStore call.
	  - Sorted maps are the registry's in-memory maps. world:failNext(n, match) / failFor(s, match)
	    rules WITH a match function also apply to them (op "get" / "set" / "update" / "remove" /
	    "range", store = the map's store name, key, writer "memorystores"); rules without a match
	    keep meaning "every DataStore call" and leave the sorted maps alone.
	  - The census map (`SW/_/census`) is one of them, so every sim server's census counts the
	    sim's servers.
]]

local Fakes = require(script.Parent.Parent.Fakes)
local OrderedFake = require(script.Parent.Parent.Fakes.OrderedStore)
local PlatformStores = require(script.Parent.Parent.Parent.server.PlatformStores)

local MemoryStores = {}

MemoryStores.WRITER = "memorystores"

-- world:_shouldFail for the sorted maps, limited to rules that name what they match
local function matchedFailure(world: any, op: string, storeName: string, key: string?): boolean
	for i = #world.failRules, 1, -1 do
		local rule = world.failRules[i]
		local expired = (rule.remaining ~= nil and rule.remaining <= 0)
			or (rule.untilTime ~= nil and world.scheduler.now >= rule.untilTime)
		if expired then
			table.remove(world.failRules, i)
		elseif rule.match ~= nil and rule.match(op, storeName, key or "", MemoryStores.WRITER) then
			if rule.remaining ~= nil then
				rule.remaining -= 1
			end
			return true
		end
	end
	return false
end

function MemoryStores.new(world: any, opts: any?): any
	local o = if opts then table.clone(opts) else {}
	local function clock(): number
		return world.scheduler:time()
	end
	o.clock = o.clock or clock
	local registry = Fakes.memoryStores(o)

	-- sorted maps: world:failNext / failFor rules with a match
	registry.shouldFail = function(op: string, storeName: string, key: string?): boolean
		return matchedFailure(world, op, storeName, key)
	end

	-- ordered stores: the World's ordered backend
	local service = world:dataStoreService({ jobId = MemoryStores.WRITER })
	local ordered: { [string]: any } = {}
	function registry.ordered(storeName: string): any
		local fake = ordered[storeName]
		if fake ~= nil then
			return fake
		end
		local id = "ordered:" .. storeName
		local ods = PlatformStores.orderedShim(service:GetOrderedDataStore(storeName), {
			getAsync = function(key: string): number?
				world:_call("GetAsync", id, key, MemoryStores.WRITER)
				local entry = world:_entry(id, key)
				return if entry then entry.value else nil
			end,
		})
		fake = OrderedFake.new({
			name = storeName,
			clock = clock,
			ods = ods,
			peek = function(): { [string]: number }
				local out = {}
				for key, entry in world.stores[id] or {} do
					out[key] = entry.value
				end
				return out
			end,
			seed = function(key: string, value: number)
				world:setOrdered(storeName, key, value)
			end,
		})
		ordered[storeName] = fake
		return fake
	end
	function registry.orderedNames(): { string }
		local out = {}
		for name in ordered do
			table.insert(out, name)
		end
		table.sort(out)
		return out
	end

	return registry
end

function MemoryStores.platform(registry: any): any
	return {
		stores = { ordered = registry.ordered, sortedMap = registry.sortedMap },
	}
end

return MemoryStores
