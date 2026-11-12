--!nocheck
--[[
	The sim's MemoryStore / OrderedDataStore stand-ins (module-api.md §23.10): one registry per World,
	shared by every simulated server (so servers see each other's sorted maps and ordered stores), on
	the World's clock (expiry follows `world:advance`).

	  MemoryStores.new(world, opts?) -> registry       Fakes.memoryStores(...) on the world's scheduler clock
	  MemoryStores.platform(registry) -> { stores = { ordered(storeName), sortedMap(storeName) } }
	                                                   the fragment a sim server's platform uses

	FOUNDATION STUB: the shared registry and the platform wiring work; the stores builder (B1) adds
	`world:failNext` for these stores, a census that counts the sim's servers, request-limit sharing
	across servers, and points the ordered side at the World's existing ordered backend.
]]

local Fakes = require(script.Parent.Parent.Fakes)

local MemoryStores = {}

function MemoryStores.new(world: any, opts: any?): any
	local o = if opts then table.clone(opts) else {}
	o.clock = o.clock or function(): number
		return world.scheduler:time()
	end
	return Fakes.memoryStores(o)
end

function MemoryStores.platform(registry: any): any
	return {
		stores = { ordered = registry.ordered, sortedMap = registry.sortedMap },
	}
end

return MemoryStores
