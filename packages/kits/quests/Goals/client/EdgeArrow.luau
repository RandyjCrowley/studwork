--!strict
--[[
	Goals client: the off-screen edge arrow (docs/framework/kits/quests.md, Goals "Edge arrow").
	One ImageLabel in its own HUD-layer ScreenGui (inside the safe area), shown when the target is
	off-screen or behind the camera, clamped to the screen edge and rotated toward the target.
	Never Active, never Selectable: it takes no input and no gamepad focus.

	  EdgeArrow.PROPS                         the label's fixed properties (specs check them)
	  EdgeArrow.SIZE / EdgeArrow.MARGIN       pixels
	  EdgeArrow.place(vp, size) -> { visible, x, y, rotation }
	      vp = { X, Y, Z } from Camera:WorldToViewportPoint, already relative to the ScreenGui's
	      origin; Z < 0 = behind the camera. size = { X, Y } (the ScreenGui's AbsoluteSize).
	  local a = EdgeArrow.new(env)            env.build() -> the ImageLabel (built lazily)
	  a:update(placement, reduced)            moves it (eased unless reduced motion), shows / hides
	  a:hide(); a:destroy()
]]

local EdgeArrow = {}
EdgeArrow.__index = EdgeArrow

EdgeArrow.SIZE = 36
EdgeArrow.MARGIN = 28
-- eased movement: the share of the remaining distance covered per update (1 = no easing)
EdgeArrow.EASE = 0.5

EdgeArrow.PROPS = table.freeze({
	Name = "GoalsEdgeArrow",
	Active = false,
	Selectable = false,
	Interactable = false,
	BackgroundTransparency = 0,
	ImageTransparency = 1,
	ZIndex = 1,
})

function EdgeArrow.place(vp: any, size: any): { visible: boolean, x: number, y: number, rotation: number }
	local w, h = size.X, size.Y
	local cx, cy = w / 2, h / 2
	local behind = vp.Z < 0
	local inside = vp.X >= 0 and vp.X <= w and vp.Y >= 0 and vp.Y <= h
	if inside and not behind then
		return { visible = false, x = vp.X, y = vp.Y, rotation = 0 }
	end
	local dx, dy = vp.X - cx, vp.Y - cy
	if behind then
		dx, dy = -dx, -dy -- the projection of a point behind the camera is mirrored
	end
	if dx == 0 and dy == 0 then
		dy = 1 -- straight behind: point down
	end
	local m = EdgeArrow.MARGIN
	local hx, hy = math.max(cx - m, 1), math.max(cy - m, 1)
	local scale = math.min(
		if dx ~= 0 then hx / math.abs(dx) else math.huge,
		if dy ~= 0 then hy / math.abs(dy) else math.huge
	)
	local rotation = math.deg(math.atan2(dy, dx)) + 90 -- the arrow's tip points up at rotation 0
	return { visible = true, x = cx + dx * scale, y = cy + dy * scale, rotation = rotation }
end

function EdgeArrow.new(env: any): any
	return setmetatable(
		{ env = env, label = nil :: any, x = nil :: number?, y = nil :: number?, visible = false },
		EdgeArrow
	)
end

function EdgeArrow.update(self: any, placement: any, reduced: boolean)
	if not placement.visible then
		self:hide()
		return
	end
	if self.label == nil then
		self.label = self.env.build()
	end
	local x, y = placement.x, placement.y
	if not reduced and self.visible and self.x ~= nil and self.y ~= nil then
		x = self.x + (x - self.x) * EdgeArrow.EASE
		y = self.y + (y - self.y) * EdgeArrow.EASE
	end
	self.x, self.y = x, y
	self.visible = true
	local label = self.label
	label.Position = UDim2.new(0, x, 0, y)
	label.Rotation = placement.rotation
	label.Visible = true
end

function EdgeArrow.hide(self: any)
	self.visible = false
	self.x, self.y = nil, nil
	if self.label ~= nil then
		self.label.Visible = false
	end
end

function EdgeArrow.destroy(self: any)
	if self.label ~= nil then
		pcall(function()
			self.label:Destroy()
		end)
		self.label = nil
	end
	self.visible = false
end

return EdgeArrow
