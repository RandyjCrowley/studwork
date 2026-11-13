--!strict
--[[
	Carry client state readers (pure): the replicated `"carry:<objectId>"` strings
	(state.modules.Carry.extra, one per object, decoded by ../shared/Codec.luau). A missing key reads as
	`idle`. Positions are never in the state: an object's own CFrame is the only source of truth.

	  State.info(state, objectId) -> Decoded?
	  State.stateOf(state, objectId) -> (state, { userId })?   idle when there is no key
	  State.carrying(state, userId) -> (objectId?, Decoded?)    the object this user holds a slot on
	  State.ids(state) -> { string }                            every object with a key (sorted)
]]

local Codec = require(script.Parent.Parent:WaitForChild("shared"):WaitForChild("Codec"))

local State = {}

local PREFIX = "carry:"

local function extra(state: any): any
	if type(state) ~= "table" or type(state.modules) ~= "table" then
		return nil
	end
	local slice = state.modules.Carry
	return if type(slice) == "table" then slice.extra else nil
end

function State.info(state: any, objectId: string): Codec.Decoded?
	local e = extra(state)
	if type(e) ~= "table" then
		return nil
	end
	return Codec.decode(e[PREFIX .. objectId])
end

function State.stateOf(state: any, objectId: string): (string?, { number }?)
	local d = State.info(state, objectId)
	if d == nil then
		return "idle", {}
	end
	return d.state, d.carriers
end

function State.ids(state: any): { string }
	local out: { string } = {}
	local e = extra(state)
	if type(e) == "table" then
		for key in e do
			if type(key) == "string" and string.sub(key, 1, #PREFIX) == PREFIX then
				table.insert(out, string.sub(key, #PREFIX + 1))
			end
		end
	end
	table.sort(out)
	return out
end

function State.carrying(state: any, userId: number): (string?, Codec.Decoded?)
	for _, id in State.ids(state) do
		local d = State.info(state, id)
		if
			d ~= nil
			and (d.state == "gathering" or d.state == "carried")
			and table.find(d.carriers, userId)
		then
			return id, d
		end
	end
	return nil, nil
end

return State
