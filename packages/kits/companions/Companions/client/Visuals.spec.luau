--!strict
local Visuals = require(game:GetService("ReplicatedStorage").Modules.Companions.client.Visuals)

local function node(class: string): any
	local value: any =
		{ ClassName = class, children = {}, CanQuery = true, CanTouch = true, CanCollide = true }
	function value:IsA(name: string): boolean
		return name == class
			or name == "BasePart" and (class == "Part" or class == "MeshPart")
			or name == "JointInstance" and (class == "Motor6D" or class == "Weld")
			or name == "LuaSourceContainer" and class == "Script"
	end
	function value:GetDescendants(): { any }
		local all = {}
		for _, child in self.children do
			table.insert(all, child)
			for _, nested in child:GetDescendants() do
				table.insert(all, nested)
			end
		end
		return all
	end
	function value:IsDescendantOf(root: any): boolean
		local parent = self.Parent
		while parent do
			if parent == root then
				return true
			end
			parent = parent.Parent
		end
		return false
	end
	function value:FindFirstChildWhichIsA(name: string): any
		for _, child in self:GetDescendants() do
			if child:IsA(name) then
				return child
			end
		end
		return nil
	end
	function value:Destroy()
		self.Parent = nil
		for _, child in self.children do
			child:Destroy()
		end
		self.children = {}
	end
	return value
end
local function attach(child: any, parent: any)
	child.Parent = parent
	table.insert(parent.children, child)
end

describe("Companion visual safety", function()
	it("sanitizes root parts and hook added geometry without world references", function()
		local root = node("Model")
		local part = node("Part")
		part.Shape = "Enum.PartType.Block"
		attach(part, root)
		local loose = node("Part")
		loose.Shape = "Enum.PartType.Block"
		attach(loose, root)
		local nilMotor = node("Motor6D")
		attach(nilMotor, part)
		local extra = node("MeshPart")
		attach(extra, root)
		local external = node("Part")
		local motor = node("Motor6D")
		motor.Part0 = part
		motor.Part1 = external
		attach(motor, part)
		local weld = node("Weld")
		weld.Part0 = part
		weld.Part1 = external
		attach(weld, part)
		local beam = node("Beam")
		beam.Attachment0 = external
		beam.Attachment1 = part
		attach(beam, part)
		local mover = node("BodyMover")
		attach(mover, part)
		local safe = node("Motor6D")
		safe.Part0 = part
		safe.Part1 = extra
		attach(safe, part)
		local scriptObject = node("Script")
		attach(scriptObject, root)
		local highlight = node("Highlight")
		highlight.Adornee = external
		attach(highlight, root)
		expect(Visuals.sanitize(root, true)).toBe(true)
		expect(part.CanQuery).toBe(false)
		expect(extra.CanTouch).toBe(false)
		expect(loose.Anchored).toBe(true)
		expect(extra.Anchored).toBe(false)
		expect(part.Anchored).toBe(true)
		expect(nilMotor.Parent).toBe(nil)
		expect(motor.Parent).toBe(nil)
		expect(weld.Parent).toBe(nil)
		expect(beam.Attachment0).toBe(nil)
		expect(beam.Attachment1).toBe(part)
		expect(mover.Parent).toBe(nil)
		expect(safe.Parent).toBe(part)
		expect(scriptObject.Parent).toBe(nil)
		expect(highlight.Adornee).toBe(nil)
		local count, triangles, unknown = Visuals.stats(root)
		expect(count).toBe(3)
		expect(triangles).toBe(24)
		expect(unknown).toBe(1)
		Visuals.sanitize(external)
		expect(external.Anchored).toBe(true)
		expect(external.CanCollide).toBe(false)
		root:Destroy()
		external:Destroy()
	end)
end)

describe("Companion custom part pivots", function()
	it("grounds translated and rotated part boxes at their actual bottom", function()
		for _, relative in
			{
				{
					Position = { X = 0, Y = -5, Z = 0 },
					RightVector = { Y = 0 },
					UpVector = { Y = 1 },
					LookVector = {
						Y = 0,
					},
				},
				{
					Position = { X = -5, Y = 0, Z = 0 },
					RightVector = { Y = -1 },
					UpVector = { Y = 0 },
					LookVector = {
						Y = 0,
					},
				},
			}
		do
			local part: any = { CFrame = {}, Size = { X = 2, Y = 4, Z = 6 } }
			function part:IsA(name: string)
				return name == "BasePart"
			end
			function part:GetPivot()
				return {
					ToObjectSpace = function(_self: any, _frame: any)
						return relative
					end,
				}
			end
			local center, height = Visuals.bounds(part)
			local pivotY = 10 - center + height / 2
			local bottom = math.huge
			for _, x in { -1, 1 } do
				for _, y in { -1, 1 } do
					for _, z in { -1, 1 } do
						local cornerY = pivotY
							+ relative.Position.Y
							+ x * part.Size.X / 2 * relative.RightVector.Y
							+ y * part.Size.Y / 2 * relative.UpVector.Y
							+ z * part.Size.Z / 2 * relative.LookVector.Y
						bottom = math.min(bottom, cornerY)
					end
				end
			end
			expect(bottom).toBe(10)
		end
	end)
end)
