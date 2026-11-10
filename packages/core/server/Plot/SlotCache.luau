--!strict
--[[
	Pure per-plot slot map cache for Core.Plot (zero dependencies, tested under Lune). M5.

	The slot map (slotId -> part, plus sorted SlotRecords limited to slotCount) used to be rebuilt
	with plot:GetDescendants() - including every display visual - several times per display
	request. Now it is built once per session (at assignment) and rebuilt only after invalidate().
	Plot wires invalidate() to DescendantAdded / DescendantRemoving of tagged slot parts that are
	NOT inside the CoreDisplays folder (see SlotCache.isSlotChange). Editing SlotId/SlotTag on a
	part that is already parented does NOT invalidate: set slot attributes before parenting.

	SlotCache.new(scan, tagOf, limit) -> cache
		scan()        -> { [slotId]: part }      the expensive walk (injected)
		tagOf(part)   -> string?                 SlotTag of a part (injected)
		limit(records, slotCount) -> records     Slots.limit (injected to stay dependency-free)
	cache:get(slotCount) -> (records, parts)     cached; re-scans only when invalidated
	cache:invalidate()
	cache.scans                                  number of scans so far (stats/tests)
]]

local SlotCache = {}
SlotCache.__index = SlotCache

export type SlotRecord = { id: string, tag: string? }

export type SlotCache = typeof(setmetatable(
	{} :: {
		scanFn: () -> { [string]: any },
		tagOf: (part: any) -> string?,
		limitFn: (records: { SlotRecord }, slotCount: number?) -> { SlotRecord },
		parts: { [string]: any }?,
		records: { SlotRecord }?,
		limitedFor: number?,
		limited: { SlotRecord }?,
		scans: number,
	},
	SlotCache
))

function SlotCache.new(
	scan: () -> { [string]: any },
	tagOf: (part: any) -> string?,
	limit: (records: { SlotRecord }, slotCount: number?) -> { SlotRecord }
): SlotCache
	return setmetatable({
		scanFn = scan,
		tagOf = tagOf,
		limitFn = limit,
		parts = nil,
		records = nil,
		limitedFor = nil,
		limited = nil,
		scans = 0,
	}, SlotCache)
end

function SlotCache.invalidate(self: SlotCache)
	self.parts = nil
	self.records = nil
	self.limited = nil
	self.limitedFor = nil
end

function SlotCache.get(self: SlotCache, slotCount: number?): ({ SlotRecord }, { [string]: any })
	local parts = self.parts
	local records = self.records
	if parts == nil or records == nil then
		self.scans += 1
		local scanned = self.scanFn()
		local list: { SlotRecord } = {}
		for id, part in scanned do
			table.insert(list, { id = id, tag = self.tagOf(part) })
		end
		parts = scanned
		records = list
		self.parts = scanned
		self.records = list
		self.limited = nil
	end
	-- slotCount comes from config; re-limit only when it differs from the cached one
	local limited = self.limited
	if limited == nil or self.limitedFor ~= slotCount then
		limited = self.limitFn(records :: { SlotRecord }, slotCount)
		self.limited = limited
		self.limitedFor = slotCount
	end
	return limited :: { SlotRecord }, parts :: { [string]: any }
end

-- Whether an added/removed descendant must invalidate the cache: only slot parts (BasePart with
-- a string SlotId) that are not inside the display folder. Visuals never invalidate.
function SlotCache.isSlotChange(isBasePart: boolean, slotId: any, insideDisplays: boolean): boolean
	return isBasePart and type(slotId) == "string" and slotId ~= "" and not insideDisplays
end

return SlotCache
