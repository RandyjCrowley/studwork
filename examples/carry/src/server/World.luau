--!strict
--[[
	Builds the carry fixture world in code (no place file needed): a ground and a spawn. The Carry
	demo (src/server/CarryWorld.luau) and the Movement demo (src/server/MovementWorld.luau) add their
	own pieces into the same folder; each file is owned by its module's builder.
]]

local Workspace = game:GetService("Workspace")

local CarryWorld = require(script.Parent.CarryWorld)
local MovementWorld = require(script.Parent.MovementWorld)

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

function World.build(): Folder
	local folder = Instance.new("Folder")
	folder.Name = "CarryWorld"

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

	CarryWorld.build(folder)
	MovementWorld.build(folder)

	folder.Parent = Workspace
	return folder
end

return World
