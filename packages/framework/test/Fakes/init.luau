--!strict
--[[
	StudWork.test.fakes (module-api.md §23.10): in-memory stand-ins for the engine services and Open
	Cloud, each recording its calls and taking failNext(n), plus the in-memory stores behind
	ctx.data.ordered / ctx.data.sortedMap.

	  StudWork.test.fakes.badgeService(opts)                    Fakes/BadgeService.luau
	  StudWork.test.fakes.textService(opts)                     Fakes/TextService.luau
	  StudWork.test.fakes.userService(opts)                     Fakes/UserService.luau
	  StudWork.test.fakes.configService(opts)                   Fakes/ConfigService.luau
	  StudWork.test.fakes.openCloud(opts)                       Fakes/OpenCloud.luau
	  StudWork.test.fakes.translator(opts)                      Fakes/Translator.luau
	  StudWork.test.fakes.experienceNotificationService(opts)   Fakes/ExperienceNotificationService.luau

	Fakes.memoryStores(opts?) -> registry   (not on the public StudWork.test.fakes; the harness, the
	  memoryStore() and the sim use it): every ordered store and sorted map by store name, so several
	  harnesses (or sim servers) that share one registry share the data.
	    opts = { clock = () -> number?, sortedMap = { structureLimit?, partitionLimit?, quotaBytes? }? }
	    registry.ordered(storeName) -> OrderedFake          registry.sortedMap(storeName) -> SortedMapFake
	    registry.orderedNames() / sortedMapNames() -> { string }
	    registry.setClock(fn)                               (first caller wins: the harness that built it)
	    registry.memoryUsed() -> number                     live bytes over every sorted map
	    registry.quotaBytes                                 the experience memory quota (nil = unlimited)
]]

local OrderedFake = require(script.OrderedStore)
local SortedMapFake = require(script.SortedMap)

local Fakes = {}

Fakes.badgeService = require(script.BadgeService).new
Fakes.textService = require(script.TextService).new
Fakes.userService = require(script.UserService).new
Fakes.configService = require(script.ConfigService).new
Fakes.openCloud = require(script.OpenCloud).new
Fakes.translator = require(script.Translator).new
Fakes.experienceNotificationService = require(script.ExperienceNotificationService).new

function Fakes.memoryStores(opts: any?): any
	local o = opts or {}
	local sm = o.sortedMap or {}
	local clock: (() -> number)? = o.clock
	local registry: any = { quotaBytes = sm.quotaBytes }
	local ordered: { [string]: any } = {}
	local sorted: { [string]: any } = {}

	local function now(): number
		return if clock ~= nil then clock() else os.time()
	end

	function registry.setClock(fn: () -> number)
		if clock == nil then
			clock = fn
		end
	end

	function registry.memoryUsed(): number
		local total = 0
		for _, map in sorted do
			total += map.memoryBytes()
		end
		return total
	end

	function registry.ordered(storeName: string): any
		local fake = ordered[storeName]
		if fake == nil then
			fake = OrderedFake.new({ name = storeName, clock = now })
			ordered[storeName] = fake
		end
		return fake
	end

	function registry.sortedMap(storeName: string): any
		local fake = sorted[storeName]
		if fake == nil then
			fake = SortedMapFake.new({
				name = storeName,
				clock = now,
				structureLimit = sm.structureLimit,
				partitionLimit = sm.partitionLimit,
				registry = registry,
			})
			sorted[storeName] = fake
		end
		return fake
	end

	local function names(map: { [string]: any }): { string }
		local out = {}
		for name in map do
			table.insert(out, name)
		end
		table.sort(out)
		return out
	end
	function registry.orderedNames(): { string }
		return names(ordered)
	end
	function registry.sortedMapNames(): { string }
		return names(sorted)
	end

	return registry
end

return Fakes
