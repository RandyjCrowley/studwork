--!strict
--[[
	Store budgets (module-api.md §23.5): request units and memory accounting for the ordered
	stores and the sorted maps, from GameConfig.storeBudgets.

	  StoreBudget.resolve(config) -> the full config with every default filled in
	  StoreBudget.new(opts) -> budget
	    opts = { config = storeBudgets?, players = () -> number, now = () -> number,
	             census = Census?, log = (string) -> () }
	    budget.allowOrdered(moduleName, requestType) -> boolean    ordered stores: false = "budget"
	    budget.chargeUnits(moduleName, units) -> boolean           sorted-map request units
	    budget.chargeMemory(moduleName, bytes) -> boolean          growing sorted-map writes
	    budget.releaseMemory(moduleName, bytes)                    a remove gives back what was charged

	STUB (foundation): the config defaults are real; the accounting always allows. The per-type
	request budget, the per-minute units, the memory shares and the usage reports are the
	stores builder's (B1) to implement behind exactly these calls.
]]

local StoreBudget = {}

StoreBudget.DEFAULTS = table.freeze({
	orderedReserve = 0.25,
	memoryUnits = table.freeze({ base = 20, perPlayer = 20 }),
	memory = table.freeze({ reserve = 0.2, defaultShare = 0.25, shares = table.freeze({}) }),
	censusSeconds = 60,
})

function StoreBudget.resolve(config: any): any
	local c = if type(config) == "table" then config else {}
	local units = if type(c.memoryUnits) == "table" then c.memoryUnits else {}
	local mem = if type(c.memory) == "table" then c.memory else {}
	return table.freeze({
		orderedReserve = if type(c.orderedReserve) == "number"
			then c.orderedReserve
			else StoreBudget.DEFAULTS.orderedReserve,
		memoryUnits = table.freeze({
			base = if type(units.base) == "number" then units.base else StoreBudget.DEFAULTS.memoryUnits.base,
			perPlayer = if type(units.perPlayer) == "number"
				then units.perPlayer
				else StoreBudget.DEFAULTS.memoryUnits.perPlayer,
		}),
		memory = table.freeze({
			reserve = if type(mem.reserve) == "number"
				then mem.reserve
				else StoreBudget.DEFAULTS.memory.reserve,
			defaultShare = if type(mem.defaultShare) == "number"
				then mem.defaultShare
				else StoreBudget.DEFAULTS.memory.defaultShare,
			shares = if type(mem.shares) == "table"
				then table.freeze(table.clone(mem.shares))
				else StoreBudget.DEFAULTS.memory.shares,
		}),
		censusSeconds = if type(c.censusSeconds) == "number"
			then c.censusSeconds
			else StoreBudget.DEFAULTS.censusSeconds,
	})
end

function StoreBudget.new(opts: any): any
	local b: any = { config = StoreBudget.resolve(opts.config) }

	function b.allowOrdered(_moduleName: string, _requestType: string): boolean
		return true -- STUB (B1)
	end

	function b.chargeUnits(_moduleName: string, _units: number): boolean
		return true -- STUB (B1)
	end

	function b.chargeMemory(_moduleName: string, _bytes: number): boolean
		return true -- STUB (B1)
	end

	function b.releaseMemory(_moduleName: string, _bytes: number) end -- STUB (B1)

	return b
end

return StoreBudget
