--!strict
--[[
	Codec: the replicated `"carry:<objectId>"` string (carry.md "Data and replication").

	  "<state>|<tag>|<u1>,<u2>,,<u4>|<wobbleSeed>|<fromUserId>,<toUserId>,<startedAt>"

	Empty slots are empty fields; the throw part is empty unless state == "thrown". Positions are never
	in it. Tags are server-chosen and may not contain "|" or ",".

	  Codec.encode({ state, tag, slots = { [index]: userId }, wobbleSeed, throw? = { from, to, startedAt } }) -> string
	  Codec.decode(str) -> { state, tag, slots = { [index]: userId }, carriers = { userId } (slot order, no holes),
	                          wobbleSeed, throw? } | nil
]]

local Codec = {}

local STATES =
	{ idle = true, gathering = true, carried = true, thrown = true, dropped = true, delivered = true }

export type Info = {
	state: string,
	tag: string,
	slots: { [number]: number },
	wobbleSeed: number,
	throw: { from: number, to: number, startedAt: number }?,
}

export type Decoded = {
	state: string,
	tag: string,
	slots: { [number]: number },
	carriers: { number },
	wobbleSeed: number,
	throw: { from: number, to: number, startedAt: number }?,
}

function Codec.encode(info: Info): string
	local top = 0
	for index in info.slots do
		top = math.max(top, index)
	end
	local fields: { string } = {}
	for i = 1, top do
		local uid = info.slots[i]
		fields[i] = if uid ~= nil then tostring(uid) else ""
	end
	local throwText = ""
	if info.state == "thrown" and info.throw ~= nil then
		throwText = string.format("%d,%d,%.3f", info.throw.from, info.throw.to, info.throw.startedAt)
	end
	return table.concat({
		info.state,
		info.tag,
		table.concat(fields, ","),
		tostring(info.wobbleSeed),
		throwText,
	}, "|")
end

function Codec.decode(text: any): Decoded?
	if type(text) ~= "string" then
		return nil
	end
	local parts = string.split(text, "|")
	if #parts ~= 5 or not STATES[parts[1]] then
		return nil
	end
	local slots: { [number]: number } = {}
	local carriers: { number } = {}
	if parts[3] ~= "" then
		for i, field in string.split(parts[3], ",") do
			if field ~= "" then
				local uid = tonumber(field)
				if uid == nil then
					return nil
				end
				slots[i] = uid
				table.insert(carriers, uid)
			end
		end
	end
	local seed = tonumber(parts[4])
	if seed == nil then
		return nil
	end
	local throw = nil
	if parts[5] ~= "" then
		local t = string.split(parts[5], ",")
		local from, to, at = tonumber(t[1]), tonumber(t[2]), tonumber(t[3])
		if from == nil or to == nil or at == nil then
			return nil
		end
		throw = { from = from, to = to, startedAt = at }
	end
	return {
		state = parts[1],
		tag = parts[2],
		slots = slots,
		carriers = carriers,
		wobbleSeed = seed,
		throw = throw,
	}
end

return Codec
