--!strict
--[[
	Goals client: the world beam (docs/framework/kits/quests.md, Goals "World beam"). Exactly one
	Beam per client between two Attachments under workspace.Terrain, from just in front of the
	character toward the target. Pure budget logic; the instances come from `env.build()` so Lune
	specs use fakes.

	  local p = Pointer.new(env, pointerConfig)
	      env.build() -> { beam, from, to }   the Beam and its two Attachments (built once, lazily)
	  p:update(now, charPos, targetPos, show) -> boolean   true when it moved or toggled the beam
	      Budget: nothing happens within `updateSeconds` of the last update, and the attachments
	      move only when the target or the character moved more than MOVE_STUDS (never per frame).
	      Hidden within `nearStuds`, beyond `maxStuds`, with no target, or when `show` is false.
	  p:hide()
	  p:destroy()
	  p.updates       how many updates went through (specs)
	  Pointer.distance(a, b) -> number
]]

local Pointer = {}
Pointer.__index = Pointer

Pointer.MOVE_STUDS = 0.5
-- the beam starts this far from the character toward the target, at about knee height
Pointer.LEAD_STUDS = 2
Pointer.DROP_STUDS = 1.5

function Pointer.distance(a: any, b: any): number
	local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Pointer.new(env: any, config: any): any
	return setmetatable({
		env = env,
		config = config,
		parts = nil :: any,
		lastAt = -math.huge,
		lastChar = nil :: any,
		lastTarget = nil :: any,
		visible = false,
		updates = 0,
	}, Pointer)
end

function Pointer.setVisible(self: any, on: boolean): boolean
	if self.visible == on then
		return false
	end
	self.visible = on
	if self.parts ~= nil then
		self.parts.beam.Enabled = on
	elseif on then
		self.parts = self.env.build()
		self.parts.beam.Enabled = true
	end
	return true
end

function Pointer.hide(self: any)
	self.lastChar = nil
	self.lastTarget = nil
	self:setVisible(false)
end

function Pointer.update(self: any, now: number, charPos: any, targetPos: any, show: boolean): boolean
	if now - self.lastAt < self.config.updateSeconds then
		return false
	end
	local cfg = self.config
	local want = show and cfg.beam ~= false and charPos ~= nil and targetPos ~= nil
	if want then
		local d = Pointer.distance(charPos, targetPos)
		want = d > cfg.nearStuds and d <= cfg.maxStuds
	end
	if not want then
		if self.visible then
			self.lastAt = now
			self.updates += 1
			self:hide()
			return true
		end
		return false
	end
	local moved = self.lastChar == nil
		or self.lastTarget == nil
		or Pointer.distance(charPos, self.lastChar) > Pointer.MOVE_STUDS
		or Pointer.distance(targetPos, self.lastTarget) > Pointer.MOVE_STUDS
	if not moved and self.visible then
		return false
	end
	self.lastAt = now
	self.updates += 1
	self.lastChar = charPos
	self.lastTarget = targetPos
	self:setVisible(true)
	local d = Pointer.distance(charPos, targetPos)
	local k = if d > 0 then math.min(Pointer.LEAD_STUDS, d) / d else 0
	local fx = charPos.X + (targetPos.X - charPos.X) * k
	local fz = charPos.Z + (targetPos.Z - charPos.Z) * k
	self.parts.from.WorldPosition = Vector3.new(fx, charPos.Y - Pointer.DROP_STUDS, fz)
	self.parts.to.WorldPosition = Vector3.new(targetPos.X, targetPos.Y, targetPos.Z)
	return true
end

function Pointer.destroy(self: any)
	if self.parts ~= nil then
		for _, inst in { self.parts.beam, self.parts.from, self.parts.to } do
			pcall(function()
				inst:Destroy()
			end)
		end
		self.parts = nil
	end
	self.visible = false
end

return Pointer
