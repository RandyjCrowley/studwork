--!strict
--[[
	Pure slot / plot selection logic for Core.Plot. Zero Roblox dependencies (tables in, tables
	out) so it runs under Lune.

	Vocabulary:
		SlotRecord = { id = "slot01", tag = "Shelf"? }   -- one pad on a plot (attributes SlotId/SlotTag)
		displayed  = PlayerData.displayed (slotId -> uid)
		owned      = set/map of uids the player owns (PlayerData.inventory, uid -> anything)
		itemTags   = ItemDef.tags of the item being placed (nil/{} = untagged item)

	Rules:
	- Slot ids sort in natural order ("slot2" < "slot10"); ties fall back to plain string order.
	- slotCount (balance.plot.slotCount) keeps the first N slots of that order (nil/invalid = all).
	- A slot with a tag accepts only items whose tags contain that tag; an untagged slot accepts any.
	- Plots sort by numeric PlotOrder first (plots with it before plots without), then natural Name.
]]

export type SlotRecord = { id: string, tag: string? }
export type PlotRecord = { name: string, order: number?, owned: boolean }

local Slots = {}

-- Reason strings returned by validateDisplay (also Plot.display's second return value).
Slots.NO_PLOT = "no_plot"
Slots.NOT_OWNED = "not_owned"
Slots.ALREADY_DISPLAYED = "already_displayed"
Slots.NO_SLOT = "no_slot"
Slots.SLOT_TAKEN = "slot_taken"
Slots.TAG_MISMATCH = "tag_mismatch"
Slots.NO_FREE_SLOT = "no_free_slot"

local function isFinite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Natural "a < b": digit runs compare numerically, everything else as plain text.
function Slots.naturalLess(a: string, b: string): boolean
	local ia, ib = 1, 1
	while ia <= #a and ib <= #b do
		local da = string.match(a, "^%d+", ia)
		local db = string.match(b, "^%d+", ib)
		if da and db then
			local na, nb = tonumber(da) :: number, tonumber(db) :: number
			if na ~= nb then
				return na < nb
			end
			ia += #da
			ib += #db
		else
			local ca, cb = string.sub(a, ia, ia), string.sub(b, ib, ib)
			if ca ~= cb then
				return ca < cb
			end
			ia += 1
			ib += 1
		end
	end
	local restA, restB = #a - ia, #b - ib
	if restA ~= restB then
		return restA < restB
	end
	return a < b
end

-- Sorted copy of the slot records (natural id order), duplicates by id dropped (first wins).
function Slots.sort(slots: { SlotRecord }): { SlotRecord }
	local seen: { [string]: boolean } = {}
	local out: { SlotRecord } = {}
	for _, slot in slots do
		if not seen[slot.id] then
			seen[slot.id] = true
			table.insert(out, slot)
		end
	end
	table.sort(out, function(x, y)
		return Slots.naturalLess(x.id, y.id)
	end)
	return out
end

-- Sorted slots limited to slotCount (nil / non-finite / < 1 = no limit). slotCount is floored.
function Slots.limit(slots: { SlotRecord }, slotCount: number?): { SlotRecord }
	local sorted = Slots.sort(slots)
	if slotCount == nil or not isFinite(slotCount) or slotCount < 1 then
		return sorted
	end
	local n = math.floor(slotCount :: number)
	local out: { SlotRecord } = {}
	for i = 1, math.min(n, #sorted) do
		out[i] = sorted[i]
	end
	return out
end

function Slots.accepts(slotTag: string?, itemTags: { string }?): boolean
	if slotTag == nil or slotTag == "" then
		return true
	end
	if itemTags == nil then
		return false
	end
	return table.find(itemTags, slotTag) ~= nil
end

function Slots.isDisplayed(displayed: { [string]: string }, uid: string): string?
	for slotId, shown in displayed do
		if shown == uid then
			return slotId
		end
	end
	return nil
end

-- First slot (in the given order) that is free and accepts the item, or nil.
function Slots.firstFree(
	slots: { SlotRecord },
	displayed: { [string]: string },
	itemTags: { string }?
): string?
	for _, slot in slots do
		if displayed[slot.id] == nil and Slots.accepts(slot.tag, itemTags) then
			return slot.id
		end
	end
	return nil
end

export type DisplayInput = {
	slots: { SlotRecord }, -- active slots (already limited), in order
	displayed: { [string]: string },
	owned: { [string]: any },
	uid: string,
	slotId: string?, -- nil = first compatible free slot
	itemTags: { string }?,
}

-- Cheap checks that need no slot lookup: run BEFORE building/reading the slot map so that
-- invalid / spammed requests never pay for it. Returns a reason or nil.
function Slots.precheck(owned: { [string]: any }, displayed: { [string]: string }, uid: string): string?
	if owned[uid] == nil then
		return Slots.NOT_OWNED
	end
	if Slots.isDisplayed(displayed, uid) ~= nil then
		return Slots.ALREADY_DISPLAYED
	end
	return nil
end

-- Rebirth reset step (M7, Plot owns `displayed`). Mutates data.displayed ONLY: clears every slot
-- unless keepDisplayed == true, and always drops slots whose uid left the inventory.
function Slots.resetDisplayed(
	data: { displayed: { [string]: string }, inventory: { [string]: any } },
	keepDisplayed: boolean?
)
	for slotId, uid in data.displayed do
		if keepDisplayed ~= true or data.inventory[uid] == nil then
			data.displayed[slotId] = nil
		end
	end
end

-- Validates a display request. Returns (slotId, nil) on success or (nil, reason).
-- Check order: not_owned, already_displayed, then (explicit slot) no_slot, slot_taken,
-- tag_mismatch / (auto slot) no_free_slot.
function Slots.validateDisplay(input: DisplayInput): (string?, string?)
	local early = Slots.precheck(input.owned, input.displayed, input.uid)
	if early ~= nil then
		return nil, early
	end
	if input.slotId == nil then
		local free = Slots.firstFree(input.slots, input.displayed, input.itemTags)
		if free == nil then
			return nil, Slots.NO_FREE_SLOT
		end
		return free, nil
	end
	local target: SlotRecord? = nil
	for _, slot in input.slots do
		if slot.id == input.slotId then
			target = slot
			break
		end
	end
	if target == nil then
		return nil, Slots.NO_SLOT
	end
	if input.displayed[target.id] ~= nil then
		return nil, Slots.SLOT_TAKEN
	end
	if not Slots.accepts(target.tag, input.itemTags) then
		return nil, Slots.TAG_MISMATCH
	end
	return target.id, nil
end

-- Slot ids of displayed entries that must be removed: uid no longer owned, the same uid shown
-- twice (later slots in sorted order lose), or (when activeSlots is given and non-empty) the slot
-- is not an active slot of the current plot. Result is sorted (natural order).
function Slots.stale(
	displayed: { [string]: string },
	owned: { [string]: any },
	activeSlots: { SlotRecord }?
): { string }
	local active: { [string]: boolean }? = nil
	if activeSlots and #activeSlots > 0 then
		local set: { [string]: boolean } = {}
		for _, slot in activeSlots do
			set[slot.id] = true
		end
		active = set
	end
	local ids: { string } = {}
	for slotId in displayed do
		table.insert(ids, slotId)
	end
	table.sort(ids, Slots.naturalLess)
	local seenUid: { [string]: boolean } = {}
	local out: { string } = {}
	for _, slotId in ids do
		local uid = displayed[slotId]
		if owned[uid] == nil or seenUid[uid] or (active ~= nil and not active[slotId]) then
			table.insert(out, slotId)
		else
			seenUid[uid] = true
		end
	end
	return out
end

export type PendingItem = { uid: string, tags: { string }? }

-- Plans auto-display: each pending item (in the given order) that is not displayed yet goes to
-- the first compatible free slot. Returns a list of { uid, slotId } (does not mutate displayed).
function Slots.planAuto(
	slots: { SlotRecord },
	displayed: { [string]: string },
	pending: { PendingItem }
): { { uid: string, slotId: string } }
	local working = table.clone(displayed)
	local plan = {}
	for _, item in pending do
		if Slots.isDisplayed(working, item.uid) == nil then
			local slotId = Slots.firstFree(slots, working, item.tags)
			if slotId then
				working[slotId] = item.uid
				table.insert(plan, { uid = item.uid, slotId = slotId })
			end
		end
	end
	return plan
end

-- Plot sort: numeric PlotOrder first (ascending), then plots without it, natural Name order.
function Slots.plotLess(a: PlotRecord, b: PlotRecord): boolean
	local oa = if a.order ~= nil and isFinite(a.order) then a.order else nil
	local ob = if b.order ~= nil and isFinite(b.order) then b.order else nil
	if oa ~= nil and ob ~= nil and oa ~= ob then
		return oa < ob
	elseif oa ~= nil and ob == nil then
		return true
	elseif oa == nil and ob ~= nil then
		return false
	end
	return Slots.naturalLess(a.name, b.name)
end

-- Index (into the given list) of the first free plot in deterministic order, or nil.
function Slots.pickPlot(plots: { PlotRecord }): number?
	local best: number? = nil
	for i, plot in plots do
		if not plot.owned then
			if best == nil or Slots.plotLess(plot, plots[best :: number]) then
				best = i
			end
		end
	end
	return best
end

return Slots
