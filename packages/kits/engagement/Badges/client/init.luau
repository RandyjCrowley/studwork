--!strict
--[[
	Badges client part (docs/framework/kits/badges.md, "Client part").

	The toast itself comes from the server through the framework feedback (text Badges.awarded with
	{ name } = the badge's Badges.badge.<key> string, in the player's language), so it shows even
	with this part replaced. This part adds:
	  StudWork.use(Badges).earned() -> { [key]: boolean }   from the replicated `awarded` (state)
	  StudWork.use(Badges).onAwarded(fn(key)) -> Connection   the server-fired module event
	                                         Awarded(key): Roblox confirmed the badge (or it was
	                                         found owned). For a game's own effect (toast = false).
	There is no client action: nothing on the client awards anything.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NAME = "Badges"

local part: { [string]: any } = {}
local handlers: { [number]: (key: string) -> () } = {}
local nextId = 0
local listening = false

local function rawState(): any
	local ok, state = pcall(function(): any
		return (require(ReplicatedStorage:WaitForChild("Framework")) :: any).Client.state()
	end)
	return if ok then state else nil
end

-- state.modules.Badges.data.awarded -> { [key]: boolean } (every recorded badge, sent or pending)
function part.earnedFrom(state: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local modules = if type(state) == "table" then state.modules else nil
	local slice = if type(modules) == "table" then modules[NAME] else nil
	local data = if type(slice) == "table" then slice.data else nil
	local awarded = if type(data) == "table" then data.awarded else nil
	if type(awarded) == "table" then
		for key, rec in awarded do
			if type(key) == "string" and type(rec) == "table" then
				out[key] = true
			end
		end
	end
	return out
end

local function listen()
	if listening then
		return
	end
	local net = part.net
	local event = if type(net) == "table" then net.Awarded else nil
	if type(event) ~= "table" or type(event.On) ~= "function" then
		return
	end
	listening = true
	event.On(function(key: any)
		if type(key) ~= "string" then
			return
		end
		for _, fn in table.clone(handlers) do
			task.spawn(fn, key)
		end
	end)
end

part.api = {
	earned = function(): { [string]: boolean }
		return part.earnedFrom(rawState())
	end,
	onAwarded = function(fn: (key: string) -> ()): any
		assert(type(fn) == "function", "Badges.onAwarded(fn): fn must be a function(key)")
		nextId += 1
		local id = nextId
		handlers[id] = fn
		listen()
		local conn: any = { Connected = true }
		function conn.Disconnect(self: any)
			self.Connected = false
			handlers[id] = nil
		end
		return conn
	end,
}

function part.start(_ctx: any)
	listen()
end

return part
