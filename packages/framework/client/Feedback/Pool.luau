--!strict
--[[
	Bounded object pool. Pure (factory/reset injected), tested under Lune.

	Pool.new(create, reset, max) -> pool
	  pool:acquire() -> item     reuses a free item; creates one while total < max; otherwise
	                             RECYCLES the oldest active item (reset first). Never exceeds max.
	  pool:release(item)         returns an active item (reset) to the free list; ignores unknown
	  pool:activeCount(), pool:total()
	  pool:active() -> { item }  oldest first (copy)
]]

export type Pool<T> = {
	acquire: (self: Pool<T>) -> T,
	release: (self: Pool<T>, item: T) -> (),
	activeCount: (self: Pool<T>) -> number,
	total: (self: Pool<T>) -> number,
	active: (self: Pool<T>) -> { T },
}

local Pool = {}

function Pool.new<T>(create: () -> T, reset: (T) -> (), max: number): Pool<T>
	assert(max >= 1, "Pool: max must be >= 1")
	local free: { T } = {}
	local active: { T } = {}
	local total = 0
	local pool = {}

	function pool.acquire(_self: Pool<T>): T
		local item: T
		if #free > 0 then
			item = table.remove(free) :: T
		elseif total < max then
			item = create()
			total += 1
		else
			item = table.remove(active, 1) :: T
			reset(item)
		end
		table.insert(active, item)
		return item
	end

	function pool.release(_self: Pool<T>, item: T)
		local index = table.find(active, item)
		if index == nil then
			return
		end
		table.remove(active, index)
		reset(item)
		table.insert(free, item)
	end

	function pool.activeCount(_self: Pool<T>): number
		return #active
	end

	function pool.total(_self: Pool<T>): number
		return total
	end

	function pool.active(_self: Pool<T>): { T }
		return table.clone(active)
	end

	return (pool :: any) :: Pool<T>
end

return Pool
