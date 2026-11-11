--!strict
--[[
	Pure sender-side gift rules for Mail (known issue R1). No Roblox globals; Mail/init.luau wires
	them to ctx, GiftSoak.spec.luau drives them with fakes.

	An escrowed gift (outbox entry with t = true) moves through the SENDER's `mail` field:
	  outbox[key]  written in the tx that took the item (txApi.send / sendInto)
	  sent[key]    after the message left (recordSent, same update as the outbox removal),
	               until the recipient takes it or it comes back
	  box[id]      when it comes back: refused by the recipient's cap ("full", before sending)
	               or not collected within returnAfter ("returned") - handBackInto, in ONE update
	               with the removal of the outbox / sent entry
	The item is in exactly one of: the sender's inventory (tx discarded), outbox, sent (and the
	recipient's queue, escrow "p"), the recipient (escrow "c"), or the sender's box.
]]

local Gifts = {}

-- Before sending an escrowed entry: reserve its slot in the recipient's record. Claimed records
-- older than `staleBefore` (if given) are pruned on the way. -> "send" | "full" | "retry"
function Gifts.prepare(escrow: any, entry: any, cap: number, staleBefore: number?): string
	if not entry.t or escrow == nil then
		return "send"
	end
	local verdict = escrow.reserve(entry.toUserId, entry.key, entry.at, cap, staleBefore)
	if verdict == "ok" then
		return "send"
	elseif verdict == "full" then
		return "full"
	end
	return "retry"
end

-- The message left: drop the outbox entry; an escrowed one is remembered in `sent`.
function Gifts.recordSent(mail: any, key: string)
	local box = mail.outbox
	local entry = if type(box) == "table" then box[key] else nil
	if entry == nil then
		return
	end
	box[key] = nil
	if entry.t then
		local sent = if type(mail.sent) == "table" then mail.sent else {}
		sent[key] = { to = entry.toUserId, kind = entry.kind, payload = entry.payload, at = entry.at }
		mail.sent = sent
	end
end

-- Mailbox id of a gift coming back ("full" | "returned"). Fits MailValidate.MAX_KEY_LENGTH (64).
function Gifts.backId(key: string, why: string): string
	local prefix = if why == "full" then "bounce-" else "return-"
	if #prefix + #key <= 64 then
		return prefix .. key
	end
	return prefix .. string.sub(key, -(64 - #prefix))
end

-- The gift comes back to its sender: held in their own mailbox (no cap: it must never be
-- dropped), its outbox / sent entry removed. Returns the mailbox id.
function Gifts.handBackInto(mail: any, entry: any, why: string, now: number): string
	local id = Gifts.backId(entry.key, why)
	if type(mail.outbox) == "table" then
		mail.outbox[entry.key] = nil
	end
	if type(mail.sent) == "table" then
		mail.sent[entry.key] = nil
	end
	local box = if type(mail.box) == "table" then mail.box else {}
	box[id] = {
		id = id,
		kind = entry.kind,
		payload = entry.payload,
		sentAt = entry.at,
		heldAt = now,
		returned = why,
	}
	mail.box = box
	return id
end

-- `sent` entries due for return at `now` (oldest key first): { { key, entry } }.
function Gifts.due(mail: any, now: number, returnAfter: number): { { key: string, entry: any } }
	local list = {}
	local sent = if type(mail) == "table" and type(mail.sent) == "table" then mail.sent else nil
	if sent == nil then
		return list
	end
	for key, entry in sent do
		if type(entry) == "table" and type(entry.at) == "number" and entry.at <= now - returnAfter then
			table.insert(list, { key = key, entry = entry })
		end
	end
	table.sort(list, function(a, b)
		return a.key < b.key
	end)
	return list
end

-- What to do with a due gift: escrow.reclaim decides. -> "return" | "forget" | "later"
function Gifts.reclaim(escrow: any, key: string, entry: any): string
	local verdict = escrow.reclaim(entry.to, key)
	if verdict == "mine" then
		return "return"
	elseif verdict == "claimed" then
		return "forget"
	end
	return "later"
end

return Gifts
