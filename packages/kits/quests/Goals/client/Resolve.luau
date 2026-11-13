--!strict
--[[
	Goals client: target resolution (docs/framework/kits/quests.md, Goals "Target resolution and
	StreamingEnabled"). No engine access of its own: every service comes in `env`, so Lune specs
	drive it with fakes.

	  local r = Resolve.new(env)
	      env.collection   CollectionService (GetTagged, GetInstanceAddedSignal,
	                       GetInstanceRemovedSignal)
	      env.root         where a `path` starts (the DataModel: "Workspace.Map.Shop")
	      env.now()        seconds (os.clock on the client)
	      env.pickers      { [name] = fn(character) -> (Vector3 | BasePart | Model)? }
	      env.positionOf?  (instance) -> Vector3? (default: BasePart.Position, Model pivot,
	                       Attachment.WorldPosition; nil once streamed out, Parent == nil)
	  r:resolve(key, target, fallback, charPos, character?) -> (Vector3?, from?)
	      from = "instance" | "lastKnown" | "fallback" | "position" | nil. `key` names the goal
	      (its id, or the next goal's text) for the last known position.
	  r:destroy()
	  r.picks                how many times a tag's nearest instance was re-picked (specs)

	A `position` target and the `fallback` are read through Resolve.toVec: array {x, y, z} or named
	{x =, y =, z =}.

	Tags: the tagged set is read with GetTagged once per tag, then kept with the Added/Removed
	signals (a streamed-out instance leaves the set); the nearest is re-picked at most every
	REPICK_SECONDS, or at once when the picked one left. When the target isn't present it falls
	back to the last known position, then `fallback`, then nothing (pill only).
]]

local Resolve = {}
Resolve.__index = Resolve

Resolve.REPICK_SECONDS = 0.5

local function defaultPositionOf(inst: any): any
	if inst == nil or inst.Parent == nil then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Model") then
		local ok, pivot = pcall(function(): any
			return inst:GetPivot()
		end)
		return if ok and pivot then pivot.Position else nil
	elseif inst:IsA("Attachment") then
		return inst.WorldPosition
	end
	return nil
end

local function isVector(v: any): boolean
	if v == nil or typeof(v) == "Instance" then
		return false
	end
	if typeof(v) == "Vector3" then
		return true
	end
	return type(v) == "table" and type(v.X) == "number" and type(v.Y) == "number" and type(v.Z) == "number"
end

local function dist2(a: any, b: any): number
	local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
	return dx * dx + dy * dy + dz * dz
end

-- A position in either form the validator accepts: { x, y, z } (array) or { x = , y = , z = } (named).
-- nil when it is neither (a bad position resolves to nothing instead of erroring).
local function toVec(t: any): any
	if typeof(t) == "Vector3" then
		return t
	end
	if type(t) ~= "table" then
		return nil
	end
	local x, y, z = t[1], t[2], t[3]
	if x == nil and y == nil and z == nil then
		x, y, z = t.x, t.y, t.z
	end
	if type(x) == "number" and type(y) == "number" and type(z) == "number" then
		return Vector3.new(x, y, z)
	end
	return nil
end
Resolve.toVec = toVec

function Resolve.new(env: any): any
	local self = setmetatable({
		env = env,
		positionOf = env.positionOf or defaultPositionOf,
		sets = {} :: { [string]: { [any]: boolean } },
		conns = {} :: { any },
		picked = {} :: { [string]: { inst: any, at: number } },
		lastKnown = {} :: { [string]: any },
		picks = 0,
	}, Resolve)
	return self
end

function Resolve.tagSet(self: any, tag: string): { [any]: boolean }
	local set = self.sets[tag]
	if set ~= nil then
		return set
	end
	set = {}
	self.sets[tag] = set
	local collection = self.env.collection
	if collection == nil then
		return set
	end
	for _, inst in collection:GetTagged(tag) do
		set[inst] = true
	end
	table.insert(
		self.conns,
		collection:GetInstanceAddedSignal(tag):Connect(function(inst: any)
			set[inst] = true
		end)
	)
	table.insert(
		self.conns,
		collection:GetInstanceRemovedSignal(tag):Connect(function(inst: any)
			set[inst] = nil
			local p = self.picked[tag]
			if p ~= nil and p.inst == inst then
				self.picked[tag] = nil -- re-pick at once
			end
		end)
	)
	return set
end

function Resolve.nearest(self: any, tag: string, charPos: any): any
	local now = self.env.now()
	local p = self.picked[tag]
	if p ~= nil and now - p.at < Resolve.REPICK_SECONDS and p.inst ~= nil and p.inst.Parent ~= nil then
		return p.inst
	end
	self.picks += 1
	local best, bestD = nil, math.huge
	for inst in self:tagSet(tag) do
		local pos = self.positionOf(inst)
		if pos ~= nil then
			local d = if charPos then dist2(pos, charPos) else 0
			if d < bestD then
				best, bestD = inst, d
			end
		end
	end
	self.picked[tag] = { inst = best, at = now }
	return best
end

function Resolve.findPath(self: any, path: string): any
	local node = self.env.root
	for segment in string.gmatch(path, "[^%.]+") do
		if node == nil then
			return nil
		end
		node = node:FindFirstChild(segment)
	end
	return node
end

-- The instance or position the target names right now (nil: not present on this client).
function Resolve.locate(self: any, target: any, charPos: any, character: any): any
	if target.tag ~= nil then
		local inst = self:nearest(target.tag, charPos)
		return if inst then self.positionOf(inst) else nil
	elseif target.path ~= nil then
		local inst = self:findPath(target.path)
		return if inst then self.positionOf(inst) else nil
	elseif target.picker ~= nil then
		local fn = self.env.pickers and self.env.pickers[target.picker]
		if fn == nil then
			return nil
		end
		local ok, result = pcall(fn, character)
		if not ok or result == nil then
			return nil
		end
		if isVector(result) then
			return result
		end
		return if typeof(result) == "Instance" or type(result) == "table"
			then self.positionOf(result)
			else nil
	end
	return nil
end

function Resolve.resolve(
	self: any,
	key: string,
	target: any,
	fallback: any,
	charPos: any,
	character: any
): (any, string?)
	if type(target) == "table" then
		local fixed = toVec(target.position)
		if fixed ~= nil then
			return fixed, "position"
		end
		local pos = self:locate(target, charPos, character)
		if pos ~= nil then
			self.lastKnown[key] = pos
			return pos, "instance"
		end
		local last = self.lastKnown[key]
		if last ~= nil then
			return last, "lastKnown"
		end
	end
	local fb = toVec(fallback)
	if fb ~= nil then
		return fb, "fallback"
	end
	return nil, nil
end

function Resolve.destroy(self: any)
	for _, conn in self.conns do
		pcall(function()
			conn:Disconnect()
		end)
	end
	table.clear(self.conns)
	table.clear(self.sets)
	table.clear(self.picked)
end

return Resolve
