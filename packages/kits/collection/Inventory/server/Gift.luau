--!strict
--[[
	Pure gifting steps for Inventory.sendGift and the "core_gift" mail receiver (v1.2). Zero
	requires: every outside fact is passed in, so the specs (incl. the never-duplicated /
	never-lost property test) run it against the real Data/Transaction.

	Gift.KIND                       reserved mail kind.
	Gift.payload(item, from, reason) the message payload: { item = { uid, itemId, mutation, meta,
	                                source, acquiredAt }, from = userId, reason? }.
	Gift.takeInto(tx, toUserId, uid, key, reason, sendInto)
	                                INSIDE one Data.update of the sender: removes inventory[uid] and
	                                queues the message (sendInto = Mail.sendInto). Returns the removed
	                                instance, or nil (nothing changed: not owned / paid source).
	                                Errors when sendInto refuses, so the caller's update is discarded
	                                (the item can never leave without its message).
	Gift.receiveInto(data, payload, opts)
	                                INSIDE one Data.update of the receiver. Returns "added" (same
	                                instance, acquiredAt = opts.now) | "duplicate" (uid already
	                                owned: idempotent success) | "full" (count >= opts.cap: the
	                                handler returns false -> mailbox). ERRORS on a malformed payload
	                                or an unknown itemId (opts.itemExists) -> Mail retries/dead-letters.
]]

local Gift = {}

Gift.KIND = "core_gift"
Gift.KEY_PREFIX = "g-"
Gift.PAID_PREFIXES = { "paid:", "paidcur:" }

function Gift.isPaidSource(source: any): boolean
	if type(source) ~= "string" then
		return false
	end
	for _, prefix in Gift.PAID_PREFIXES do
		if string.sub(source, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local function copyMeta(meta: any): any
	return if type(meta) == "table" then table.clone(meta) else nil
end

function Gift.payload(item: any, fromUserId: number, reason: string?): { [string]: any }
	return {
		item = {
			uid = item.uid,
			itemId = item.itemId,
			mutation = item.mutation,
			meta = copyMeta(item.meta),
			source = item.source,
			acquiredAt = item.acquiredAt,
		},
		from = fromUserId,
		reason = reason,
	}
end

export type SendInto = (
	tx: any,
	toUserId: number,
	kind: string,
	payload: { [string]: any },
	key: string
) -> boolean

function Gift.takeInto(
	tx: any,
	toUserId: number,
	uid: string,
	key: string,
	reason: string?,
	sendInto: SendInto
): any
	local inventory = tx.data.inventory
	local item = inventory[uid]
	if item == nil or Gift.isPaidSource(item.source) then
		return nil
	end
	inventory[uid] = nil
	if not sendInto(tx, toUserId, Gift.KIND, Gift.payload(item, tx.player.UserId, reason), key) then
		error("[Core.Inventory] gift message rejected", 0) -- discards the whole update
	end
	return item
end

export type ReceiveOptions = {
	itemExists: (itemId: string) -> boolean,
	cap: number,
	now: number,
}

local function count(map: { [string]: any }): number
	local n = 0
	for _ in map do
		n += 1
	end
	return n
end

function Gift.receiveInto(data: any, payload: any, opts: ReceiveOptions): (string, any)
	local item = if type(payload) == "table" then payload.item else nil
	if
		type(item) ~= "table"
		or type(item.uid) ~= "string"
		or #item.uid == 0
		or type(item.itemId) ~= "string"
	then
		error("[Core.Inventory] malformed gift payload", 0)
	end
	if not opts.itemExists(item.itemId) then
		error("[Core.Inventory] gift of unknown item " .. item.itemId, 0)
	end
	local inventory = data.inventory
	if inventory[item.uid] ~= nil then
		return "duplicate", inventory[item.uid]
	end
	if count(inventory) >= opts.cap then
		return "full", nil
	end
	local instance = {
		uid = item.uid,
		itemId = item.itemId,
		mutation = if type(item.mutation) == "string" then item.mutation else nil,
		acquiredAt = opts.now,
		source = if type(item.source) == "string" then item.source else nil,
		meta = copyMeta(item.meta),
	}
	inventory[item.uid] = instance
	return "added", instance
end

return Gift
