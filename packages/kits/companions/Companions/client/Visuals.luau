--!strict
local Visuals = {}
local function inside(root: Instance, value: Instance?): boolean
	return value == nil or value == root or value:IsDescendantOf(root)
end
function Visuals.sanitize(root: Instance, rig: boolean?): boolean
	root.Parent = nil
	local all = root:GetDescendants()
	table.insert(all, root)
	local adjacency: { [Instance]: { Instance } } = {}
	local motorRoot: BasePart? = nil
	local function internalMotor(node: any): boolean
		return node.Part0 ~= nil
			and node.Part1 ~= nil
			and inside(root, node.Part0)
			and inside(root, node.Part1)
	end
	for _, node in all do
		if node:IsA("Motor6D") and internalMotor(node) then
			local a, b = node.Part0 :: BasePart, node.Part1 :: BasePart
			motorRoot = motorRoot or a
			adjacency[a] = adjacency[a] or {}
			adjacency[b] = adjacency[b] or {}
			table.insert(adjacency[a], b)
			table.insert(adjacency[b], a)
		end
	end
	local primary = if root:IsA("Model")
		then root.PrimaryPart or motorRoot or root:FindFirstChildWhichIsA("BasePart", true)
		elseif root:IsA("BasePart") then root
		else nil
	local connected: { [Instance]: boolean } = {}
	local pending: { Instance } = if primary then { primary } else {}
	while #pending > 0 do
		local part = table.remove(pending) :: Instance
		if connected[part] then
			continue
		end
		connected[part] = true
		local neighbors: { Instance } = adjacency[part] or {}
		for _, neighbor in neighbors do
			if not connected[neighbor] then
				table.insert(pending, neighbor)
			end
		end
	end

	local geometry = false
	for _, node in all do
		if
			node:IsA("LuaSourceContainer")
			or node:IsA("BodyMover")
			or node:IsA("WeldConstraint")
			or node:IsA("NoCollisionConstraint")
			or node:IsA("Constraint") and not node:IsA("NoCollisionConstraint")
		then
			node:Destroy()
		elseif node:IsA("Humanoid") then
			local animator = node:FindFirstChildWhichIsA("Animator")
			if animator then
				local controller = Instance.new("AnimationController")
				controller.Parent = root
				animator.Parent = controller
			end
			node:Destroy()
		elseif node:IsA("JointInstance") then
			if not node:IsA("Motor6D") or not internalMotor(node) then
				node:Destroy()
			end
		elseif node:IsA("BasePart") then
			geometry = true
			node.Anchored = not (rig and connected[node] and node ~= primary)
			node.CanCollide = false
			node.CanQuery = false
			node.CanTouch = false
		end
		-- Reference-bearing effects must never attach the clone to world geometry.
		if node:IsA("Beam") or node:IsA("Trail") then
			if not inside(root, node.Attachment0) then
				(node :: any).Attachment0 = nil
			end
			if not inside(root, node.Attachment1) then
				(node :: any).Attachment1 = nil
			end
		elseif node:IsA("Highlight") or node:IsA("BillboardGui") or node:IsA("SurfaceGui") then
			if not inside(root, node.Adornee) then
				(node :: any).Adornee = nil
			end
		end
	end
	return geometry
end
function Visuals.placeholder(): BasePart
	local part = Instance.new("Part")
	part.Size = Vector3.one
	Visuals.sanitize(part)
	return part
end
function Visuals.bounds(root: any): (number, number)
	if root:IsA("BasePart") then
		local relative = root:GetPivot():ToObjectSpace(root.CFrame)
		local height = math.abs(relative.RightVector.Y) * root.Size.X
			+ math.abs(relative.UpVector.Y) * root.Size.Y
			+ math.abs(relative.LookVector.Y) * root.Size.Z
		return relative.Position.Y, height
	end
	local cf, size = root:GetBoundingBox()
	return root:GetPivot():PointToObjectSpace(cf.Position).Y, size.Y
end
function Visuals.stats(root: Instance): (number, number, number)
	local parts, triangles, unknown = 0, 0, 0
	local all = root:GetDescendants()
	table.insert(all, root)
	for _, node in all do
		if node:IsA("BasePart") then
			parts += 1
			if node:IsA("Part") and tostring(node.Shape) == "Enum.PartType.Block" then
				triangles += 12
			else
				unknown += 1
			end
		end
	end
	return parts, triangles, unknown
end
return Visuals
