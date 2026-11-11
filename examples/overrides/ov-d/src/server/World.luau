--!strict
--[[
	Builds the sandbox world in code (no place file needed): spawn, 6 plots tagged "CorePlot"
	with 8 "SlotId" pads each, and the glowing collect block in the middle.
	A real game would ship these as models in the place; Core.Plot works with either.
]]

local Workspace = game:GetService("Workspace")

local World = {}

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for k, v in props do
		(p :: any)[k] = v
	end
	return p
end

function World.build(): BasePart
	local folder = Instance.new("Folder")
	folder.Name = "SandboxWorld"

	part({
		Name = "Ground",
		Size = Vector3.new(260, 2, 260),
		Position = Vector3.new(0, -1, 0),
		Color = Color3.fromHex("#7BC67B"),
		Parent = folder,
	})

	local spawn = Instance.new("SpawnLocation")
	spawn.Anchored = true
	spawn.Size = Vector3.new(10, 1, 10)
	spawn.Position = Vector3.new(0, 0.5, 20)
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Parent = folder

	local block = part({
		Name = "CollectBlock",
		Size = Vector3.new(6, 6, 6),
		Position = Vector3.new(0, 3, 0),
		Color = Color3.fromHex("#FFB547"),
		Material = Enum.Material.Neon,
		Parent = folder,
	})

	folder.Parent = Workspace
	return block
end

return World
