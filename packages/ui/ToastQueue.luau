--!strict
--[[
	Pure toast queue (zero dependencies; the caller injects `now`).

	ToastQueue.new(opts?) -> Queue        opts: maxVisible (3), duration (seconds, 3), maxPending (20)
	ToastQueue.push(q, text, now, rarity?) -> id
		A toast with the same text as one already visible/pending bumps its count (x2) and,
		when visible, restarts its timer instead of stacking duplicates.
	ToastQueue.tick(q, now) -> boolean    expire visible toasts, promote pending; true if changed
	ToastQueue.dismiss(q, id, now) -> boolean
	ToastQueue.nextDeadline(q) -> number? earliest expiry among visible toasts
]]

export type Toast = {
	id: number,
	text: string,
	rarity: string?,
	count: number,
	expiresAt: number,
}

export type Queue = {
	visible: { Toast },
	pending: { Toast },
	nextId: number,
	maxVisible: number,
	duration: number,
	maxPending: number,
}

export type Options = { maxVisible: number?, duration: number?, maxPending: number? }

local DEFAULT_MAX_VISIBLE = 3
local DEFAULT_DURATION = 3
local DEFAULT_MAX_PENDING = 20

local ToastQueue = {}

function ToastQueue.new(opts: Options?): Queue
	local o: Options = opts or {}
	return {
		visible = {},
		pending = {},
		nextId = 1,
		maxVisible = math.max(1, o.maxVisible or DEFAULT_MAX_VISIBLE),
		duration = math.max(0.1, o.duration or DEFAULT_DURATION),
		maxPending = math.max(0, o.maxPending or DEFAULT_MAX_PENDING),
	}
end

local function promote(q: Queue, now: number): boolean
	local changed = false
	while #q.visible < q.maxVisible and #q.pending > 0 do
		local t = table.remove(q.pending, 1) :: Toast
		t.expiresAt = now + q.duration
		table.insert(q.visible, t)
		changed = true
	end
	return changed
end

function ToastQueue.push(q: Queue, text: string, now: number, rarity: string?): number
	for _, t in q.visible do
		if t.text == text and t.rarity == rarity then
			t.count += 1
			t.expiresAt = now + q.duration
			return t.id
		end
	end
	for _, t in q.pending do
		if t.text == text and t.rarity == rarity then
			t.count += 1
			return t.id
		end
	end
	local id = q.nextId
	q.nextId += 1
	table.insert(q.pending, { id = id, text = text, rarity = rarity, count = 1, expiresAt = math.huge })
	while #q.pending > q.maxPending do
		table.remove(q.pending, 1)
	end
	promote(q, now)
	return id
end

function ToastQueue.tick(q: Queue, now: number): boolean
	local changed = false
	for i = #q.visible, 1, -1 do
		if q.visible[i].expiresAt <= now then
			table.remove(q.visible, i)
			changed = true
		end
	end
	return promote(q, now) or changed
end

function ToastQueue.dismiss(q: Queue, id: number, now: number): boolean
	for _, list in { q.visible, q.pending } do
		for i, t in list do
			if t.id == id then
				table.remove(list, i)
				promote(q, now)
				return true
			end
		end
	end
	return false
end

function ToastQueue.nextDeadline(q: Queue): number?
	local best: number? = nil
	for _, t in q.visible do
		if best == nil or t.expiresAt < best then
			best = t.expiresAt
		end
	end
	return best
end

return ToastQueue
