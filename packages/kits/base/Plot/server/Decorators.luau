--!strict
-- Appearance callbacks must finish before the final safety pass.
local function invoke(fn: any, ...: any)
	local thread = coroutine.create(fn)
	coroutine.resume(thread, ...)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
	end
end
-- Plot owns its visual safety boundary; no dependency on any appearance provider.
local Decorators = {}
function Decorators.sanitize(root: Instance): boolean
	root.Parent = nil
	local all = root:GetDescendants()
	table.insert(all, root)
	local geometry = false
	for _, node in all do
		if
			node:IsA("LuaSourceContainer")
			or node:IsA("Humanoid")
			or node:IsA("BodyMover")
			or node:IsA("Constraint")
			or node:IsA("JointInstance")
			or node:IsA("WeldConstraint")
		then
			node:Destroy()
		elseif node:IsA("BasePart") then
			geometry = true
			node.Anchored = true
			node.CanCollide = false
			node.CanQuery = false
			node.CanTouch = false
		elseif node:IsA("Beam") or node:IsA("Trail") then
			local a, b = node.Attachment0, node.Attachment1
			if a and a ~= root and not a:IsDescendantOf(root) then
				(node :: any).Attachment0 = nil
			end
			if b and b ~= root and not b:IsDescendantOf(root) then
				(node :: any).Attachment1 = nil
			end
		elseif node:IsA("Highlight") or node:IsA("BillboardGui") or node:IsA("SurfaceGui") then
			local adornee = node.Adornee
			if adornee and adornee ~= root and not adornee:IsDescendantOf(root) then
				(node :: any).Adornee = nil
			end
		end
	end
	return geometry
end
-- Bounds are measured only after the provider's final visual has been sanitized.
function Decorators.place(visual: any, surface: CFrame, frames: any?): (number, BasePart?)
	local constructor = frames or CFrame
	if visual:IsA("Model") then
		local bounds, size = visual:GetBoundingBox()
		local offset = visual:GetPivot():PointToObjectSpace(bounds.Position)
		visual:PivotTo(surface * constructor.new(-offset.X, size.Y / 2 - offset.Y, -offset.Z))
		return size.Y, visual.PrimaryPart or visual:FindFirstChildWhichIsA("BasePart", true)
	end
	local relative = visual:GetPivot():ToObjectSpace(visual.CFrame)
	local offset = relative.Position
	local height = math.abs(relative.RightVector.Y) * visual.Size.X
		+ math.abs(relative.UpVector.Y) * visual.Size.Y
		+ math.abs(relative.LookVector.Y) * visual.Size.Z
	visual:PivotTo(surface * constructor.new(-offset.X, height / 2 - offset.Y, -offset.Z))
	return height, visual
end
function Decorators.new(dirty: () -> (), createPart: (() -> BasePart)?)
	local records: { any } = {}
	return {
		decorate = function(id: string, fn: (Instance, any, any) -> ())
			assert(type(id) == "string" and #id > 0 and type(fn) == "function", "invalid decorator")
			for _, record in records do
				assert(record.id ~= id, "duplicate decorator")
			end
			local record = { id = id, fn = fn }
			table.insert(records, record)
			dirty()
			return {
				Invalidate = function(_self: any)
					if table.find(records, record) then
						dirty()
					end
				end,
				Disconnect = function(_self: any)
					local index = table.find(records, record)
					if index then
						table.remove(records, index)
						dirty()
					end
				end,
			}
		end,
		apply = function(visual: Instance, def: any, copy: any): Instance
			Decorators.sanitize(visual)
			local destroyed = false
			local connection = visual.Destroying:Connect(function()
				destroyed = true
			end)
			for _, record in records do
				invoke(record.fn, visual, def, copy)
			end
			connection:Disconnect()
			local ok, geometry = pcall(Decorators.sanitize, visual)
			if destroyed or not ok or not geometry then
				visual:Destroy()
				local fallback: BasePart = if createPart then createPart() else Instance.new("Part")
				fallback.Size = Vector3.new(1, 1, 1)
				visual = fallback
				Decorators.sanitize(visual)
			end
			return visual
		end,
	}
end
return Decorators
